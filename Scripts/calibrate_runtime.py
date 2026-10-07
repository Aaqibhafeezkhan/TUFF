#!/usr/bin/env python3
"""Opt-in, model-local calibration of existing TUFF prefill chunks and expert cache slots.

Uses a packaged TUFFDecodeService, one loaded model at a time. It changes no
app settings. Recommendations are per model and prompt shape, and keep the
baseline unless at least three paired repetitions match its greedy output
and improve complete-request time beyond both the gain threshold and noise.
This does not enable speculative decoding or download prediction weights.
Cache sweeps are optional and limited to Gemma 26B/Flash Next, 16/24/32 slots,
at least 16 GiB unified memory and at most 4096 context tokens. They do not
constitute a generalized guarantee against memory pressure.
"""
import argparse
import json
import math
from pathlib import Path
import statistics
import subprocess
import time
import uuid

from benchmark_conversation_cache import (
    Service, answer, digest, generation, model_options, source_identity,
)
from benchmark_reporting import machine_state, require_idle_inference

CHUNKS = (32, 64, 128, 256, 512, 1024, 2048)
CACHE_SLOTS = (16, 24, 32)
CACHE_SWEEP_MODELS = {'gemma4', 'qwen38-flash-next'}
PROMPTS = {
    'short': 'Explain briefly why a lighthouse uses a rotating beam.',
    'long': ('The log records clear skies, calm seas, a white lighthouse beam, '
             'and a ship approaching the coast. ' * 80)
            + '\nSummarize the log in two sentences.',
}


def cache_sweep(value, models, context, memory_bytes):
    if value is None:
        return None
    slots = list(dict.fromkeys(int(v) for v in value.split(',')))
    if not slots or any(v not in CACHE_SLOTS for v in slots):
        raise ValueError(f'cache slots must be selected from {CACHE_SLOTS}')
    if not set(models) <= CACHE_SWEEP_MODELS:
        raise ValueError('cache-slot calibration supports only gemma4 and qwen38-flash-next')
    if memory_bytes < 16 * 1024 ** 3 or context > 4096:
        raise ValueError('cache-slot calibration requires at least 16 GiB and context at most 4096')
    return slots


def recommend(rows, baseline, repeat, minimum_gain, baseline_slots=None):
    """Conservative paired selection, with every rejected candidate explained."""
    result = dict(selected=baseline, applied=False, candidates=[])
    def identity(row):
        return (row['preset'], row['cache_slots']) if baseline_slots is not None else row['preset']
    baseline_identity = (baseline, baseline_slots) if baseline_slots is not None else baseline
    if baseline_slots is not None:
        result['selected_cache_slots'] = baseline_slots
    base = {r['repeat']: r for r in rows if identity(r) == baseline_identity}
    for preset in dict.fromkeys(identity(r) for r in rows if identity(r) != baseline_identity):
        candidate = {r['repeat']: r for r in rows if identity(r) == preset}
        item = dict(preset=preset[0] if baseline_slots is not None else preset, admitted=False)
        if baseline_slots is not None:
            item['cache_slots'] = preset[1]
        result['candidates'].append(item)
        if repeat < 3 or set(base) != set(range(1, repeat + 1)) or set(candidate) != set(base):
            item['reason'] = 'fewer than three complete paired repetitions'
            continue
        pairs = [(base[i], candidate[i]) for i in sorted(base)]
        if any(a['status'] != 'finished' or b['status'] != 'finished' for a, b in pairs):
            item['reason'] = 'load or admission refused' if any(r['status'] == 'load-refused' for pair in pairs for r in pair) else 'generation failure'
            continue
        if any(a['output'] != b['output'] for a, b in pairs):
            item['reason'] = 'greedy output differs from the baseline'
            continue
        if any(a['prompt_tokens'] != b['prompt_tokens']
               or a.get('cached_tokens', 0) or b.get('cached_tokens', 0) for a, b in pairs):
            item['reason'] = 'prompt identity or cold-prefill mismatch'
            continue
        fields = ('wall_seconds', 'prefill_seconds', 'decode_seconds', 'peak_memory_bytes')
        if any(not isinstance(r.get(k), (int, float)) or not math.isfinite(r[k]) or r[k] <= 0
               for pair in pairs for r in pair for k in fields):
            item['reason'] = 'missing or invalid timing/memory evidence'
            continue
        gains = [(a['wall_seconds'] - b['wall_seconds']) / a['wall_seconds'] for a, b in pairs]
        median = statistics.median(gains)
        mad = statistics.median(abs(gain - median) for gain in gains)
        item.update(paired_gains=gains, median_gain=median, median_absolute_deviation=mad)
        if min(gains) <= 0 or median - 2 * mad <= minimum_gain:
            item['reason'] = 'gain is too small, inconsistent, or within observed noise'
            continue
        if statistics.median(b['decode_seconds'] / a['decode_seconds'] for a, b in pairs) > 1.03:
            item['reason'] = 'decode regressed by more than 3 percent'
            continue
        if statistics.median(b['peak_memory_bytes'] / a['peak_memory_bytes'] for a, b in pairs) > 1.05:
            item['reason'] = 'peak memory increased by more than 5 percent'
            continue
        item.update(admitted=True, reason='matching output and repeatable complete-request gain')
    admitted = [r for r in result['candidates'] if r['admitted']]
    if admitted:
        winner = max(admitted, key=lambda r: r['median_gain'])
        result['selected'] = winner['preset']
        if baseline_slots is not None:
            result['selected_cache_slots'] = winner['cache_slots']
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--service', type=Path, required=True)
    parser.add_argument('--model-root', type=Path, required=True)
    parser.add_argument('--models', default='gemma4,qwen38-flash-next')
    parser.add_argument('--chunks', default='128,512,2048')
    parser.add_argument('--cache-slots', help='optional 16,24,32 sweep; Gemma 26B/Flash Next only, >=16 GiB, context <=4096')
    parser.add_argument('--shapes', default='short,long')
    parser.add_argument('--repeat', type=int, default=3)
    parser.add_argument('--minimum-gain', type=float, default=0.05)
    parser.add_argument('--context', type=int, default=4096)
    parser.add_argument('--max-new', type=int, default=64)
    parser.add_argument('--timeout', type=int, default=1800)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    try:
        chunks = list(dict.fromkeys(int(v) for v in args.chunks.split(',')))
        shapes = list(dict.fromkeys(args.shapes.split(',')))
        if not chunks or any(v not in CHUNKS for v in chunks):
            raise ValueError(f'chunks must be selected from {CHUNKS}')
        if not shapes or any(v not in PROMPTS for v in shapes):
            raise ValueError('shapes must be short and/or long')
        if args.repeat < 3 or not 0 < args.minimum_gain < 1 or not math.isfinite(args.minimum_gain):
            raise ValueError('at least three repetitions and a gain between zero and one are required')
        if args.context < 2048 or args.max_new < 2 or args.timeout <= 0:
            raise ValueError('context must be at least 2048, max-new at least 2 and timeout positive')
        if args.service.name != 'TUFFDecodeService' or '/Applications/' in str(args.service.resolve()):
            raise ValueError('use a packaged TUFFDecodeService outside /Applications')
        models = list(dict.fromkeys(args.models.split(',')))
        for model in models:
            model_options(args, model)
        memory_bytes = int(subprocess.check_output(['sysctl', '-n', 'hw.memsize'], text=True)) if args.cache_slots is not None else 0
        cache_slots = cache_sweep(args.cache_slots, models, args.context, memory_bytes)
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        parser.error(str(error))
    require_idle_inference()
    args.output.mkdir(parents=True, exist_ok=True)
    identity = dict(source=source_identity(), service_sha256=digest(args.service),
                    machine=machine_state(), arguments={k: str(v) for k, v in vars(args).items()})
    (args.output / 'identity.json').write_text(json.dumps(identity, indent=2))
    rows, recommendations = [], []
    for model in models:
        require_idle_inference()
        directory, options = model_options(args, model)
        model_path = args.model_root / directory
        manifest = model_path / 'manifest.json'
        baseline = options['prefillChunkTokens']
        presets = list(dict.fromkeys([baseline] + chunks))
        baseline_slots = options['expertCacheSlots']
        slot_presets = list(dict.fromkeys([baseline_slots] + (cache_slots or [])))
        for shape in shapes:
            for repeat in range(1, args.repeat + 1):
                slot_order = slot_presets if repeat % 2 else list(reversed(slot_presets))
                for slots in slot_order:
                    require_idle_inference()
                    runtime_base = options | {'expertCacheSlots': slots}
                    log = args.output / f'{model}-{shape}-r{repeat}-slots{slots}.stderr.txt'
                    # Cache buffers are part of the loaded model identity. A
                    # fresh service prevents overlapping allocations and avoids
                    # comparing a request against the wrong loaded settings.
                    service = Service(args.service, {'TUFF_CONVERSATION_CACHE_MB': '0'}, log)
                    try:
                        order = presets if repeat % 2 else list(reversed(presets))
                        for chunk in order:
                            runtime = runtime_base | {'prefillChunkTokens': chunk}
                            # Chunk size belongs to SessionLoadKey, just like
                            # expert slots. Load this exact configuration before
                            # its warmup and measured request.
                            load = dict(modelPath=str(model_path), maxContextTokens=args.context,
                                        runtimeOptions=runtime, forceLogitsHead=False,
                                        requestID=str(uuid.uuid4()))
                            load_started = time.monotonic()
                            loaded = service.request({'load': {'_0': load}}, args.timeout)[-1]
                            load_seconds = time.monotonic() - load_started
                            if loaded['kind'] != 'ready':
                                if slots == baseline_slots and chunk == baseline:
                                    raise RuntimeError(f'{model}: baseline load failed: {loaded}')
                                rows.append(dict(model=model, shape=shape, repeat=repeat,
                                                 preset=chunk, cache_slots=slots,
                                                 runtime_options=runtime,
                                                 status='load-refused', error=loaded.get('error'),
                                                 load_seconds=load_seconds))
                                (args.output / 'rows.json').write_text(json.dumps(rows, indent=2))
                                print(f"{model} {shape} r{repeat} chunk={chunk} slots={slots}: "
                                      f"load refused: {loaded.get('error')}", flush=True)
                                continue
                            request = generation(args, runtime, PROMPTS[shape], [], str(uuid.uuid4()))
                            # Every measurement gets the same warmup; retained
                            # reuse is disabled and cached_tokens must be zero.
                            warmup = service.request({'generate': {'_0': request}}, args.timeout)[-1]
                            if warmup['kind'] != 'finished':
                                raise RuntimeError(f'{model}: warmup failed: {warmup}')
                            request['generationID'] = str(uuid.uuid4())
                            started = time.monotonic()
                            events = service.request({'generate': {'_0': request}}, args.timeout)
                            wall = time.monotonic() - started
                            terminal = events[-1]
                            row = dict(model=model, shape=shape, repeat=repeat, preset=chunk,
                                       cache_slots=slots, load_seconds=load_seconds,
                                       runtime_options=runtime, request=request, manifest_sha256=digest(manifest),
                                       status=terminal['kind'], error=terminal.get('error'),
                                       output=answer(events), wall_seconds=wall,
                                       prompt_tokens=terminal.get('promptTokenCount'),
                                       cached_tokens=terminal.get('cachedPromptTokens') or 0,
                                       prefill_seconds=terminal.get('prefillSeconds'),
                                       decode_seconds=terminal.get('decodeSeconds'),
                                       generated_tokens=terminal.get('tokenCount'),
                                       stop_reason=terminal.get('stopReason'),
                                       decode_tokens_per_second=terminal.get('tokensPerSecond'),
                                       peak_memory_bytes=terminal.get('peakMemoryBytes'),
                                       current_memory_bytes=terminal.get('currentMemoryBytes'))
                            rows.append(row)
                            (args.output / 'rows.json').write_text(json.dumps(rows, indent=2))
                            print(f"{model} {shape} r{repeat} chunk={chunk} slots={slots}: {terminal['kind']} "
                                  f"prefill={row['prefill_seconds']} wall={wall:.3f}s", flush=True)
                    finally:
                        service.close()
            selected = recommend([r for r in rows if r['model'] == model and r['shape'] == shape],
                                 baseline, args.repeat, args.minimum_gain,
                                 baseline_slots=baseline_slots if cache_slots is not None else None)
            selected.update(model=model, shape=shape, baseline=baseline,
                            baseline_cache_slots=baseline_slots,
                            runtime_options=options | {'prefillChunkTokens': selected['selected'],
                                                       'expertCacheSlots': selected.get('selected_cache_slots', baseline_slots)})
            recommendations.append(selected)
    summary = dict(recommendations=recommendations, applied=False,
                   note='Recommendations only. App settings and production defaults are unchanged.')
    (args.output / 'recommendations.json').write_text(json.dumps(summary, indent=2))
    print(json.dumps(summary, indent=2))
    return int(any(r['status'] != 'finished' for r in rows))


if __name__ == '__main__':
    raise SystemExit(main())
