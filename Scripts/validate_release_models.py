#!/usr/bin/env python3
"""Serial Paris and photo smoke tests using a packaged app's inference runner.

Keep output under benchmark-results/: photo paths and model responses are private.
Resume is allowed only with the same runner, harness, photo, and run settings.
Without --image only the Paris runs are made; a later --resume that adds
--image runs the photo checks against the same runner, or --text-only marks
the sweep finished with the Paris runs alone.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import time
from benchmark_reporting import machine_state, resolved_settings, summarize, expert_io, require_idle_inference
from benchmark_inference import sys_exit_signal

ROOT = Path(__file__).resolve().parent.parent
VISION_MODELS = {'gemma4-e2b', 'gemma4-e4b', 'gemma4-12b-qat', 'gemma4',
                 'qwen36', 'qwen38-flash-next'}
FOOTER = re.compile(r'\[stop=(\S+) prefill=(\d+)tok/([0-9.]+)s new=(\d+)tok decode=([0-9.]+)s tok/s=([0-9.]+)\]')
PHOTO_PROMPT = ('Describe the visible objects and clothing in this photo in two short sentences. '
                'Include what is on the person\'s head and face. Do not guess their identity.')


def digest(path):
    value = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def atomic_json(path, value):
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(value, indent=2) + '\n')
    temporary.replace(path)


def selected_models(models, selection):
    if selection is None:
        return models
    names = selection.split(',')
    if not names or any(name not in models for name in names) or len(set(names)) != len(names):
        raise ValueError('models must be a nonempty list of distinct supported model names')
    return {name: config for name, config in models.items() if name in names}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', required=True, type=Path)
    parser.add_argument('--model-root', required=True, type=Path)
    parser.add_argument('--image', type=Path)
    parser.add_argument('--image-prompt', default=PHOTO_PROMPT)
    parser.add_argument('--image-keywords', default='glasses,towel',
                        help='comma-separated words required by the image smoke check')
    parser.add_argument('--text-only', action='store_true',
                        help='finish the sweep with the Paris runs alone')
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--repeat', type=int, default=3)
    parser.add_argument('--models', help='Limit a targeted recheck to comma-separated supported model names')
    parser.add_argument('--timeout', type=int, default=2400)
    parser.add_argument('--resume', action='store_true')
    args = parser.parse_args()
    if args.text_only and args.image:
        parser.error('--text-only and --image are exclusive')
    if args.repeat < 1 or args.timeout < 1:
        parser.error('repeat and timeout must be positive')
    cli = args.app.resolve() / 'Contents/Resources/bin/TUFFCLI'
    image = args.image.resolve() if args.image else None
    model_root = args.model_root.resolve()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    metadata = json.loads(subprocess.check_output(
        ['ruby', '-rjson', '-e', 'require File.expand_path("Scripts/benchmark_models", Dir.pwd); '
         'puts JSON.generate({models: BENCHMARK_MODELS, labels: BENCHMARK_MODEL_LABELS})'], cwd=ROOT))
    try:
        metadata['models'] = selected_models(metadata['models'], args.models)
    except ValueError as error:
        parser.error(str(error))
    identity = dict(cli_sha256=digest(cli), harness_sha256=digest(__file__),
                    reporting_sha256=digest(ROOT / 'Scripts/benchmark_reporting.py'),
                    source_sha256=hashlib.sha256(''.join(
                        str(p.relative_to(ROOT)) + digest(p)
                        for p in sorted((ROOT / 'Sources').rglob('*')) if p.is_file()).encode()).hexdigest(),
                    shaders_sha256=hashlib.sha256(''.join(
                        str(p.relative_to(args.app.resolve())) + digest(p)
                        for p in sorted(args.app.resolve().rglob('*'))
                        if p.suffix in {'.metal', '.metallib'}).encode()).hexdigest(),
                    model_table_sha256=digest(ROOT / 'Scripts/benchmark_models.rb'),
                    image_sha256=digest(image) if image else None,
                    image_prompt=args.image_prompt, image_keywords=args.image_keywords, model_root=str(model_root), repeat=args.repeat,
                    models=list(metadata['models']),
                    timeout=args.timeout, prompt_sha256=digest(ROOT / 'docs/benchmark-prompts/capital-of-france.json'))
    result_path = output / 'results.json'
    if result_path.exists():
        report = json.loads(result_path.read_text())
        previous = dict(report['identity'])
        # A Paris-only sweep may gain its photo later; nothing else may change.
        if previous.get('image_sha256') is None:
            previous['image_sha256'] = identity['image_sha256']
        if not args.resume or previous != identity:
            parser.error('existing results require --resume and identical inputs/binary')
        report['identity'] = identity
        report.pop('finished', None)
    else:
        report = dict(identity=identity, started=time.time(),
                      commit=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
                      worktree_status=subprocess.check_output(['git', 'status', '--short'], cwd=ROOT, text=True),
                      hardware=subprocess.check_output(['sysctl', '-n', 'hw.model', 'hw.memsize'], text=True).strip(),
                      validation_scope="keyword correctness smoke; not quality or sustained performance qualification",
                      machine_state=machine_state(), results=[])
    completed = {(r['model'], r['kind'], r['attempt']) for r in report['results']}
    for row in report['results']:
        if 'manifest_sha256' in row:
            current = model_root / Path(metadata['models'][row['model']]['path']).name / 'manifest.json'
            if digest(current) != row['manifest_sha256']:
                parser.error('installed model metadata changed since the previous run')
        if 'vision_manifest_sha256' in row:
            name = Path(metadata['models'][row['model']]['path']).name.removesuffix('.gturbo')
            if digest(model_root / (name + '.vision.gturbo') / 'manifest.json') != row['vision_manifest_sha256']:
                parser.error('installed image pack metadata changed since the previous run')
    for kind in ('paris', 'vision'):
        ordered = sorted(metadata['models'].items(), key=lambda item: (
            {"qwen38-flash-next": 0, "gemma4": 1}.get(item[0], 2)))
        for model, config in ordered:
            if kind == 'vision' and (model not in VISION_MODELS or image is None):
                continue
            model_dir = model_root / Path(config['path']).name
            manifest = model_dir / 'manifest.json'
            for attempt in range(args.repeat if kind == 'paris' else 1):
                if (model, kind, attempt) in completed:
                    continue
                require_idle_inference()
                row = dict(model=model, label=metadata['labels'][model], kind=kind, attempt=attempt,
                           started=time.time(), status='failed')
                prefix = output / f'{kind}-{model}-{attempt + 1}'
                command = ['/usr/bin/time', '-l', str(cli), '--model', str(model_dir),
                           '--max-context', '4096', '--max-new', str(512 if kind == 'vision' else (256 if model == 'minimax-m2.7' else 128)), '--seed', '20260721',
                           *config['chat'], *config['sampling'], *config['runtime']]
                if kind == 'paris':
                    command += ['--messages-file', str(ROOT / 'docs/benchmark-prompts/capital-of-france.json')]
                else:
                    command += ['--chat-prompt', args.image_prompt, '--image', str(image)]
                row['machine_state_before'] = machine_state()
                row['command'] = command
                row['max_new_tokens'] = int(command[command.index('--max-new') + 1])
                try:
                    row['manifest_sha256'] = digest(manifest)
                    model_manifest = json.loads(manifest.read_text())
                    if kind == 'vision':
                        pack = model_root / (model_dir.name.removesuffix('.gturbo') + '.vision.gturbo')
                        row['vision_manifest_sha256'] = digest(pack / 'manifest.json')
                    with Path(str(prefix) + '.stdout.txt').open('w') as stdout, Path(str(prefix) + '.stderr.txt').open('w') as stderr:
                        proc = subprocess.Popen(command, cwd=ROOT, stdout=stdout, stderr=stderr,
                                                start_new_session=True, env=dict(os.environ, TUFF_PHASES='1'))
                        try:
                            proc.wait(timeout=args.timeout)
                        except subprocess.TimeoutExpired:
                            os.killpg(proc.pid, signal.SIGTERM)
                            try:
                                proc.wait(timeout=5)
                            except subprocess.TimeoutExpired:
                                os.killpg(proc.pid, signal.SIGKILL)
                                proc.wait()
                            raise
                        except BaseException:
                            if proc.poll() is None:
                                os.killpg(proc.pid, signal.SIGTERM)
                                try:
                                    proc.wait(timeout=5)
                                except subprocess.TimeoutExpired:
                                    os.killpg(proc.pid, signal.SIGKILL)
                                    proc.wait()
                            raise
                    row['exit_code'] = proc.returncode
                    answer = Path(str(prefix) + '.stdout.txt').read_text()
                    stderr = Path(str(prefix) + '.stderr.txt').read_text()
                    row['stdout_sha256'] = digest(Path(str(prefix) + '.stdout.txt'))
                    row['resolved_settings'] = resolved_settings(stderr)
                    row['expert_io'] = expert_io(stderr)
                    footer = FOOTER.search(stderr)
                    if footer:
                        row.update(stop=footer[1], prompt_tokens=int(footer[2]), prefill_seconds=float(footer[3]),
                                   generated_tokens=int(footer[4]), decode_seconds=float(footer[5]), tps=float(footer[6]))
                    rss = re.search(r'(\d+)\s+maximum resident set size', stderr)
                    if rss:
                        row['peak_rss_bytes'] = int(rss[1])
                    checks = ({'names_paris': bool(re.search(r'\bParis\b', answer, re.I))} if kind == 'paris' else
                              {word: bool(re.search(r'\b' + re.escape(word) + r'\b', answer, re.I))
                               for word in args.image_keywords.split(',') if word})
                    allocated = re.search(r'allocated expert slot bytes: (\d+)', stderr)
                    if model_manifest.get('expertStride', 0):
                        slots = int(command[command.index('--expert-cache-slots') + 1])
                        stride = model_manifest['expertStride']
                        page = os.sysconf('SC_PAGESIZE')
                        expected = ((stride + page - 1) // page * page
                                    * model_manifest['numLayers']
                                    * min(slots, model_manifest['expertsPerLayer']))
                        row['expected_expert_slot_bytes'] = expected
                        row['allocated_expert_slot_bytes'] = int(allocated[1]) if allocated else None
                        checks['expert_slot_allocation_matches_manifest'] = bool(allocated and int(allocated[1]) == expected)
                    row['checks'] = checks
                    # Keywords are a smoke check; keep every full response for human review.
                    row['status'] = 'passed' if proc.returncode == 0 and footer and row['resolved_settings'] and checks and all(checks.values()) else 'needs_review'
                except FileNotFoundError as exc:
                    row.update(status='unavailable', error=str(exc))
                except subprocess.TimeoutExpired:
                    row.update(status='timeout', error=f'exceeded {args.timeout} seconds')
                row['wall_seconds'] = time.time() - row['started']
                row['machine_state_after'] = machine_state()
                report['results'].append(row)
                report['summaries'] = summarize(report['results'])
                atomic_json(result_path, report)
                print(f"{kind} {model}: {row['status']}, prefill={row.get('prefill_seconds', '?')}s, TPS={row.get('tps', '?')}", flush=True)
    if image is not None or args.text_only:
        report['finished'] = time.time()
        report['photo_checks'] = 'run' if image is not None else 'skipped'
    else:
        print('Paris runs finished; resume with --image to add the photo checks.', flush=True)
    atomic_json(result_path, report)
    return 0 if all(r['status'] == 'passed' for r in report['results']) else 1


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, lambda signum, frame: sys_exit_signal(signum))
    raise SystemExit(main())
