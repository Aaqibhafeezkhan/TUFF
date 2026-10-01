"""Shared evidence helpers. Machine-state fields are unavailable when a probe fails."""
import json
import re
import statistics
import subprocess


def machine_state():
    commands = {
        'memory_pressure': ['memory_pressure', '-Q'],
        'swap_usage': ['sysctl', '-n', 'vm.swapusage'],
        'vm_stat': ['vm_stat'],
        'thermal': ['pmset', '-g', 'therm'],
        'power': ['pmset', '-g', 'batt'],
        'macos': ['sw_vers', '-productVersion'],
        'hardware': ['sysctl', '-n', 'hw.model', 'hw.memsize', 'machdep.cpu.brand_string'],
    }
    state = {}
    for name, command in commands.items():
        try:
            result = subprocess.run(command, capture_output=True, text=True, timeout=10)
            state[name] = {'available': result.returncode == 0 and bool(result.stdout.strip()),
                           'value': result.stdout.strip() if result.returncode == 0 else None}
        except (OSError, subprocess.TimeoutExpired):
            state[name] = {'available': False, 'value': None}
    return state


def resolved_settings(stderr):
    match = re.search(r'^\[resolved inference settings\] (.*)$', stderr, re.M)
    return json.loads(match[1]) if match else None


def expert_io(stderr):
    result = {}
    for purpose in ('demand', 'prefetch'):
        match = re.search(r'logical ' + purpose + r' expert reads: (\d+), bytes: (\d+), failures: (\d+)', stderr)
        if match:
            result[purpose] = dict(reads=int(match[1]), bytes=int(match[2]), failures=int(match[3]))
    wait = re.search(r'exposed prefetch wait: ([0-9.]+) ms', stderr)
    if wait:
        result['exposed_prefetch_wait_ms'] = float(wait[1])
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
