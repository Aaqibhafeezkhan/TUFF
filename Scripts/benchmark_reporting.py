"""Shared evidence helpers. Machine-state fields are unavailable when a probe fails."""
import json
import re
import statistics
import subprocess
from pathlib import Path


def inference_processes():
    """Record executable names, never command arguments that may contain user text."""
    output = subprocess.check_output(['ps', '-axo', 'pid=,comm='], text=True, timeout=10)
    names = {'TUFF', 'TUFFCLI', 'TUFFDecodeService', 'TUFFServer', 'xctest',
             'swift-frontend', 'ollama', 'llama-server', 'mlx_lm'}
    processes = []
    for line in output.splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) == 2:
            name = Path(fields[1]).name
            if name in names or name.endswith('PackageTests.xctest'):
                processes.append(dict(pid=int(fields[0]), executable=name))
    return processes


def require_idle_inference():
    processes = inference_processes()
    if processes:
        raise RuntimeError(f'Other inference, test or compiler processes are active: {processes}')


def machine_state():
    commands = {
        'memory_pressure': ['memory_pressure', '-Q'],
        'swap_usage': ['sysctl', '-n', 'vm.swapusage'],
        'vm_stat': ['vm_stat'],
        'thermal': ['pmset', '-g', 'therm'],
        'power': ['pmset', '-g', 'batt'],
        'macos': ['sw_vers', '-productVersion'],
        'hardware': ['sysctl', '-n', 'hw.model', 'hw.memsize', 'machdep.cpu.brand_string'],
        'load_average': ['sysctl', '-n', 'vm.loadavg'],
        'cpu_summary': ['top', '-l', '1', '-n', '0'],
    }
    state = {}
    for name, command in commands.items():
        try:
            result = subprocess.run(command, capture_output=True, text=True, timeout=10)
            state[name] = {'available': result.returncode == 0 and bool(result.stdout.strip()),
                           'value': result.stdout.strip() if result.returncode == 0 else None}
        except (OSError, subprocess.TimeoutExpired):
            state[name] = {'available': False, 'value': None}
    try:
        state['inference_processes'] = {'available': True, 'value': inference_processes()}
    except (OSError, subprocess.SubprocessError):
        state['inference_processes'] = {'available': False, 'value': None}
    return state


def resolved_settings(stderr):
    match = re.search(r'^\[resolved inference settings\] (.*)$', stderr, re.M)
    return json.loads(match[1]) if match else None


def expert_io(stderr):
    result = {}
    requests = re.search(r'cache demand requests: (\d+), predictions: (\d+)',stderr)
    if requests:
        result['demand_requests'] = int(requests[1])
        result['prediction_requests'] = int(requests[2])
    for purpose in ('demand', 'prefetch'):
        match = re.search(r'logical ' + purpose + r' expert reads: (\d+), bytes: (\d+), failures: (\d+)', stderr)
        if match:
            result[purpose] = dict(reads=int(match[1]), bytes=int(match[2]), failures=int(match[3]))
    wait = re.search(r'exposed prefetch wait: ([0-9.]+) ms', stderr)
    if wait:
        result['exposed_prefetch_wait_ms'] = float(wait[1])
    cache = re.search(r'useful prefetched records: (\d+), evicted unused: (\d+)', stderr)
    if cache:
        result['useful_prefetch_reads'] = int(cache[1])
        result['unused_prefetch_evictions'] = int(cache[2])
    return result


def summarize(rows):
    """Retain every observation; failures never disappear behind a winning run."""
    summaries = []
    for model in dict.fromkeys(row['model'] for row in rows):
        runs = [row for row in rows if row['model'] == model and row['kind'] == 'paris']
        if not runs:
            continue
        summary = dict(model=model, attempts=len(runs),
                       smoke_passes=sum(row['status'] == 'passed' for row in runs))
        for field in ('tps', 'prefill_seconds', 'decode_seconds', 'wall_seconds', 'peak_rss_bytes'):
            values = [row[field] for row in runs if field in row]
            summary[field] = (dict(values=values, median=statistics.median(values),
                                   minimum=min(values), maximum=max(values),
                                   spread=max(values) - min(values)) if values else None)
        summaries.append(summary)
    return summaries
