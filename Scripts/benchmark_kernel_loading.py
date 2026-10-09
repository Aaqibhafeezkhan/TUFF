#!/usr/bin/env python3
"""Compare per-model kernel groups with the single combined shader library.

Each repetition starts a fresh decode service process per variant, loads each
model in turn (so later loads are model switches inside one process), runs one
short greedy generation per model, and records load wall time, the kernel
groups compiled and their compile times, memory after each load and after the
generation, prefill and decode time, and the output text. Variants:

  grouped   the 8.0 default: each model compiles only its kernel groups
  combined  TUFF_KERNEL_GROUPS=combined, every module in one library as before

Shader compiles hit the system Metal cache after the first run of a source,
so these are warm-cache loads. Cold front-end compile time is measured
separately; see the 8.0.0 release notes.
"""
import argparse
import json
from pathlib import Path
import re
import time
import uuid

from benchmark_conversation_cache import Service, answer, digest, model_options, source_identity
from benchmark_reporting import machine_state, require_idle_inference

PROMPT = 'Name two ways to stay dry.'


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--service', type=Path, required=True)
    p.add_argument('--model-root', type=Path, required=True)
    p.add_argument('--models', default='gemma4,qwen38-flash-next')
    p.add_argument('--repeat', type=int, default=3)
    p.add_argument('--max-new', type=int, default=24)
    p.add_argument('--context', type=int, default=4096)
    p.add_argument('--timeout', type=int, default=1800)
    p.add_argument('--allow-busy', action='store_true')
    p.add_argument('--output', type=Path, required=True)
    args = p.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / 'identity.json').write_text(json.dumps(dict(
        source=source_identity(), service_sha256=digest(args.service), machine=machine_state(),
        arguments={k: str(v) for k, v in vars(args).items()}), indent=2))
    rows = []
    for repeat in range(1, args.repeat + 1):
        variants = ['grouped', 'combined'] if repeat % 2 else ['combined', 'grouped']
        for variant in variants:
            if not args.allow_busy:
                require_idle_inference()
            environment = {'TUFF_LOG_KERNELS': '1'}
            if variant == 'combined':
                environment['TUFF_KERNEL_GROUPS'] = 'combined'
            log = args.output / f'{variant}-{repeat}.stderr.txt'
            service = Service(args.service, environment, log)
            try:
                for index, model in enumerate(args.models.split(',')):
                    directory, options = model_options(args, model)
                    load = dict(modelPath=str(args.model_root / directory), maxContextTokens=args.context,
                                runtimeOptions=options, forceLogitsHead=False, requestID=str(uuid.uuid4()))
                    started = time.monotonic()
                    ready = service.request({'load': {'_0': load}}, args.timeout)[-1]
                    load_seconds = time.monotonic() - started
                    request = dict(prompt=PROMPT, history=[], maxNewTokens=args.max_new,
                                   maxContextTokens=args.context, reasoning='off', preserveThinking=False,
                                   temperature=0, repetitionPenalty=1, seed=20261006,
                                   runtimeOptions=options, generationID=str(uuid.uuid4()))
                    generation_started = time.monotonic()
                    events = service.request({'generate': {'_0': request}}, args.timeout)
                    request_seconds = time.monotonic() - generation_started
                    terminal = events[-1]
                    row = dict(repeat=repeat, variant=variant, model=model, load_order=index,
                               load_status=ready['kind'], load_seconds=load_seconds,
                               memory_after_load=ready.get('currentMemoryBytes'),
                               memory_after_generation=terminal.get('currentMemoryBytes'),
                               peak_memory=terminal.get('peakMemoryBytes'),
                               prefill_seconds=terminal.get('prefillSeconds'),
                               decode_seconds=terminal.get('decodeSeconds'),
                               request_seconds=request_seconds,
                               tokens=terminal.get('tokenCount'), status=terminal['kind'],
                               output=answer(events))
                    rows.append(row)
                    print(f"r{repeat} {variant} {model}: load={load_seconds:.2f}s "
                          f"mem={row['memory_after_load']} prefill={row['prefill_seconds']} "
                          f"decode={row['decode_seconds']} {row['status']}", flush=True)
            finally:
                service.close()
            text = log.read_text()
            for row in rows:
                if row['repeat'] == repeat and row['variant'] == variant:
                    row['kernel_log'] = re.findall(r'\[kernels\][^\n]*', text)
                    row['late_kernel_groups'] = text.count('was not prepared')
    (args.output / 'rows.json').write_text(json.dumps(rows, indent=2))
    mismatches = []
    for model in args.models.split(','):
        outputs = {(r['variant'], r['repeat']): r['output'] for r in rows if r['model'] == model}
        if len(set(outputs.values())) > 1:
            mismatches.append(model)
    summary = dict(rows=len(rows), failures=sum(r['status'] != 'finished' for r in rows),
                   late_loads=sum(r.get('late_kernel_groups', 0) for r in rows),
                   output_mismatches=mismatches)
    (args.output / 'summary.json').write_text(json.dumps(summary, indent=2))
    print(json.dumps(summary, indent=2))
    return 1 if summary['failures'] or mismatches else 0


if __name__ == '__main__':
    raise SystemExit(main())
