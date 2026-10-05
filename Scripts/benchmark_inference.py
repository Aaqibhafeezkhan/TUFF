#!/usr/bin/env python3
"""Sequential, repeatable inference comparisons. Fresh processes have cold runner caches.
Filesystem caches are uncontrolled; a repeated run is labelled accordingly.
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
from benchmark_reporting import machine_state, resolved_settings, expert_io, require_idle_inference

ROOT = Path(__file__).resolve().parents[1]
FOOTER = re.compile(r'\[stop=(\S+) prefill=(\d+)tok/([0-9.]+)s new=(\d+)tok decode=([0-9.]+)s tok/s=([0-9.]+)\]')


def sys_exit_signal(signum):
    raise SystemExit(128+signum)


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def shader_digest(cli):
    root = next((p for p in Path(cli).parents if p.suffix == '.app'), Path(cli).parent)
    bundles = list(root.rglob('TUFF_TUFFEngine.bundle'))
    if len(bundles) != 1:
        raise ValueError('expected one engine resource bundle beside the CLI')
    bundle = bundles[0]
    files = sorted(p for p in bundle.rglob('*') if p.suffix in ('.metal','.metallib'))
    if not files:
        raise ValueError('missing shader resources')
    return hashlib.sha256(''.join(str(p.relative_to(bundle))+digest(p) for p in files).encode()).hexdigest()


SHAPES = ('tiny', 'short', 'long')


def environment_overrides(args, variant):
    # A reference without its own value inherits the candidate's, so a
    # comparison changes only the switches it names.
    reference = variant == 'reference'
    lookahead = (args.comparison_lookahead or args.lookahead) if reference else args.lookahead
    small_block = (args.comparison_small_block or args.small_block) if reference else args.small_block
    environment = {}
    if lookahead:
        environment['TUFF_EXPERT_LOOKAHEAD'] = lookahead
    if small_block:
        environment['TUFF_SMALL_BLOCK_PREFILL'] = small_block
    return environment


def prompt(shape):
    if shape == 'tiny':
        # Short enough that the templated prompt stays below the 32-token
        # batched-prefill threshold on the default models. Check prompt_tokens
        # in the results rather than assuming it.
        return 'Name two ways to stay dry.'
    if shape == 'short':
        return 'Explain how a coastal town can prepare for a week of heavy rain. Give practical steps for residents and the council.'
    # Distinct records keep expert choices from becoming a repeating calibration loop.
    records = '\n'.join(f'Day {i+1}: rainfall {7+(i*13)%51} mm, wind {9+(i*7)%32} km/h, river level {1+(i*11)%29}/30, blocked drains {(i*3)%8}, available crews {2+(i*5)%7}.' for i in range(28))
    return 'Review these observations from a coastal town.\n' + records + '\nExplain the main risks and propose a prioritized flood preparation plan for residents and the council.'


def run(command, prefix, timeout, environment=None):
    require_idle_inference()
    before = machine_state()
    started_utc = time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime())
    start = time.monotonic()
    with Path(str(prefix)+'.stdout.txt').open('w') as out, Path(str(prefix)+'.stderr.txt').open('w') as err:
        proc = subprocess.Popen(command, cwd=ROOT, stdout=out, stderr=err,
                                start_new_session=True, env=dict(os.environ, TUFF_PHASES='1', **(environment or {})))
        try:
            proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGTERM)
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGKILL)
                proc.wait()
        except BaseException:
            if proc.poll() is None:
                os.killpg(proc.pid, signal.SIGTERM)
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(proc.pid, signal.SIGKILL)
                    proc.wait()
            raise
    stderr = Path(str(prefix)+'.stderr.txt').read_text()
    footer = FOOTER.search(stderr)
    result = dict(command=command, exit_code=proc.returncode, wall_seconds=time.monotonic()-start,
                  started_utc=started_utc,finished_utc=time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()),
                  machine_state_before=before, machine_state_after=machine_state(),
                  resolved_settings=resolved_settings(stderr), expert_io=expert_io(stderr),
                  stdout_sha256=digest(Path(str(prefix)+'.stdout.txt')))
    rss = re.search(r'(\d+)\s+maximum resident set size', stderr)
    if rss:
        result['peak_rss_bytes'] = int(rss[1])
    if footer:
        result.update(stop=footer[1], prompt_tokens=int(footer[2]), prefill_seconds=float(footer[3]),
                      generated_tokens=int(footer[4]), decode_seconds=float(footer[5]), tps=float(footer[6]))
    valid = (proc.returncode == 0 and footer and result['resolved_settings']
             and result['prompt_tokens'] > 0 and result['generated_tokens'] > 0
             and result['decode_seconds'] > 0 and result['tps'] > 0
             and all(result['expert_io'].get(role, {}).get('failures', 0) == 0
                     for role in ('demand', 'prefetch')))
    result['status'] = 'passed' if valid else 'failed'
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cli', type=Path, required=True)
    parser.add_argument('--comparison-cli', type=Path, help='Alternate this reference binary with --cli in each repetition')
    parser.add_argument('--model-root', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--models', default='qwen38-flash-next,gemma4')
    parser.add_argument('--shapes', default='short,long')
    parser.add_argument('--modes', default='greedy,sampled')
    parser.add_argument('--repeat', type=int, default=3)
    parser.add_argument('--max-new', type=int, default=32)
    parser.add_argument('--timeout', type=int, default=1800)
    parser.add_argument('--slots', type=int, help='Candidate expert-cache slot override')
    parser.add_argument('--comparison-slots', type=int, help='Reference slot override; otherwise use model defaults')
    parser.add_argument('--chunk', type=int, help='Candidate prefill chunk override')
    parser.add_argument('--comparison-chunk', type=int, help='Reference chunk override; otherwise use model defaults')
    parser.add_argument('--lookahead', choices=['on','off'])
    parser.add_argument('--comparison-lookahead', choices=['on','off'])
    parser.add_argument('--small-block', choices=['on','off'],
                        help='TUFF_SMALL_BLOCK_PREFILL for the candidate (default: unset, which is off)')
    parser.add_argument('--comparison-small-block', choices=['on','off'],
                        help='TUFF_SMALL_BLOCK_PREFILL for the reference')
    args = parser.parse_args()
    if min(args.repeat,args.max_new,args.timeout) < 1:
        parser.error('repeat, max-new and timeout must be positive')
    if any(x not in SHAPES for x in args.shapes.split(',')):
        parser.error('--shapes accepts ' + ','.join(SHAPES))
    if any(x not in ('greedy','sampled') for x in args.modes.split(',')):
        parser.error('--modes accepts greedy,sampled')
    if any(value is not None for value in (args.comparison_lookahead,args.comparison_small_block,args.comparison_slots,args.comparison_chunk)) and not args.comparison_cli:
        parser.error('comparison overrides require --comparison-cli')
    if any(value is not None and value < 1 for value in (args.slots,args.comparison_slots,args.chunk,args.comparison_chunk)):
        parser.error('slot and chunk overrides must be positive')
    args.output.mkdir(parents=True, exist_ok=True)
    metadata = json.loads(subprocess.check_output(['ruby','-rjson','-e',
        'require File.expand_path("Scripts/benchmark_models", Dir.pwd); puts JSON.generate(BENCHMARK_MODELS)'], cwd=ROOT))
    cli = args.cli.resolve()
    comparison = args.comparison_cli.resolve() if args.comparison_cli else None
    identity = dict(cli_sha256=digest(cli), shaders_sha256=shader_digest(cli),
                    comparison_cli_sha256=digest(comparison) if comparison else None,
                    comparison_shaders_sha256=shader_digest(comparison) if comparison else None,
                    harness_sha256=digest(__file__),
                    reporting_sha256=digest(ROOT/'Scripts/benchmark_reporting.py'),
                    model_table_sha256=digest(ROOT/'Scripts/benchmark_models.rb'),
                    model_manifests={m:digest(args.model_root/Path(metadata[m]['path']).name/'manifest.json')
                                     for m in args.models.split(',')},
                    commit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),
                    options={k:str(v) if isinstance(v,Path) else v for k,v in vars(args).items()},
                    cache_scope='Cold runner expert/KV caches per process. Filesystem cache uncontrolled; successive attempts are repeated OS-cache observations.')
    path = args.output/'results.json'
    if path.exists():
        report = json.loads(path.read_text())
        if report['identity'] != identity:
            parser.error('output identity changed; use a new output directory')
    else:
        report = dict(identity=identity, results=[])
    report.pop('finished',None)
    done = {(r['model'],r['shape'],r['mode'],r['attempt'],r.get('variant','primary')) for r in report['results']}
    for model in args.models.split(','):
        config = metadata[model]
        model_dir = args.model_root/Path(config['path']).name
        for shape in args.shapes.split(','):
            messages = args.output/f'{shape}.json'
            messages.write_text(json.dumps([dict(role='user',content=prompt(shape))]))
            for mode in args.modes.split(','):
                for attempt in range(args.repeat):
                    sampling = config['sampling'] if mode == 'sampled' else ['--temperature','0']
                    binaries = [('reference',comparison),('candidate',cli)] if comparison else [('primary',cli)]
                    if comparison and attempt % 2:
                        binaries.reverse()
                    for variant,binary in binaries:
                        if (model,shape,mode,attempt,variant) in done:
                            continue
                        runtime = list(config['runtime'])
                        slots = args.comparison_slots if variant=='reference' else args.slots
                        chunk = args.comparison_chunk if variant=='reference' else args.chunk
                        for option,value in [('--expert-cache-slots',slots),('--prefill-chunk-tokens',chunk)]:
                            if value is not None:
                                runtime[runtime.index(option)+1] = str(value)
                        command = ['/usr/bin/time','-l',str(binary),'--model',str(model_dir),'--messages-file',str(messages),
                            '--max-context','4096','--max-new',str(args.max_new),'--seed','20260721',*config['chat'],*sampling,*runtime]
                        prefix = args.output/f'{model}-{shape}-{mode}-{attempt+1}-{variant}'
                        environment = environment_overrides(args, variant)
                        row = run(command,prefix,args.timeout,environment)
                        row['environment_overrides'] = environment
                        manifest = json.loads((model_dir/'manifest.json').read_text())
                        row.update(model_identity={k:manifest[k] for k in ('modelID','sourceSnapshotHash','arch','quant') if k in manifest},
                                   model=model,shape=shape,mode=mode,attempt=attempt,variant=variant,
                                   cli_sha256=digest(binary),prompt_sha256=digest(messages),
                                   manifest_sha256=digest(model_dir/'manifest.json'))
                        report['results'].append(row)
                        temp = path.with_suffix('.tmp')
                        temp.write_text(json.dumps(report,indent=2)); temp.replace(path)
                        print(f"{model} {shape} {mode} {attempt+1} {variant}: {row['status']}, prefill={row.get('prefill_seconds')}, TPS={row.get('tps')}",flush=True)
    report['finished'] = time.time()
    path.write_text(json.dumps(report,indent=2))
    return 0 if all(r['status']=='passed' for r in report['results']) else 1


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, lambda signum, frame: sys_exit_signal(signum))
    raise SystemExit(main())
