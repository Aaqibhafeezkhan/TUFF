#!/usr/bin/env python3
"""Write a sanitized release smoke report, retaining every repetition in summaries."""
import argparse
import datetime
import json
from pathlib import Path
import re
from benchmark_reporting import summarize

ROOT = Path(__file__).resolve().parent.parent


def probe(state, name):
    item = state.get(name, {})
    if not item.get('available') or not item.get('value'):
        return 'unavailable'
    return item['value'].replace('|', '\\|').replace('\n', '; ')


def memory_free(state):
    value = probe(state, 'memory_pressure')
    match = re.search(r'System-wide memory free percentage: (\d+)%', value)
    return match[1] + '%' if match else 'unavailable'


def vm_counters(state):
    value = probe(state, 'vm_stat')
    counters = [re.search(r'\b' + name + r':\s+(\d+)', value)
                for name in ('Pageins', 'Pageouts', 'Swapins', 'Swapouts')]
    return ', '.join(match[1] for match in counters) if all(counters) else 'unavailable'


def render(report, version):
    rows = report['results']
    text_rows = [row for row in rows if row['kind'] == 'paris']
    vision = [row for row in rows if row['kind'] == 'vision']
    date = datetime.datetime.fromtimestamp(report['started']).astimezone().date()
    hardware = report.get('hardware', 'unavailable').replace('\n', ', ')
    lines = [f'# TUFF {version} model validation', '', f'Host model and memory: {hardware}.', '',
             f'Measured {date}. These are short correctness smoke checks, not model-quality '
             'or sustained-performance qualification. Each attempt uses a fresh process. '
             'Decode rate excludes load and prefill. Prefill includes first-use expert integrity checks; '
             'filesystem caching is uncontrolled. Timings may overlap; logical expert '
             'reads include OS-cache hits and do not measure physical SSD traffic.', '',
             f"Text smoke passes: {sum(row['status'] == 'passed' for row in text_rows)}/{len(text_rows)}. "
             f"Image smoke passes: {sum(row['status'] == 'passed' for row in vision)}/{len(vision)}.", '',
             '| Model | All decode rates (tok/s) | Median | Min..max | Spread | Prefill median | Peak RSS max |',
             '| --- | --- | ---: | --- | ---: | ---: | ---: |']
    labels = {row['model']: row['label'] for row in rows}
    eligible = {summary['model']: summary for summary in summarize(
        [row for row in rows if row.get('performance_eligible', True)])}
    for summary in summarize(rows):
        measured = eligible.get(summary['model'])
        rates = measured['tps'] if measured else None
        if not rates:
            lines.append(f"| {labels[summary['model']]} | unavailable | | | | | |")
            continue
        prefill = measured['prefill_seconds']
        rss = measured['peak_rss_bytes']
        values = ', '.join(f"{row['tps']:.3f}" + ('†' if not row.get('performance_eligible', True) else '')
                           for row in text_rows if row['model']==summary['model'] and 'tps' in row)
        lines.append(f"| {labels[summary['model']]} | {values} | {rates['median']:.3f} | "
                     f"{rates['minimum']:.3f}..{rates['maximum']:.3f} | {rates['spread']:.3f} | "
                     f"{prefill['median']:.2f} s | {rss['maximum']/1048576:.0f} MiB |")
    excluded = [row for row in rows if not row.get('performance_eligible', True)]
    if excluded:
        lines += ['', '† Timing excluded from median, range, spread, prefill and RSS summaries. '
                  'Every raw observation remains in this report. Exclusions require a recorded '
                  'measurement interruption; slow or failed runs are otherwise retained.', '']
        lines += [f"- {row['label']} / {row['kind']} / attempt {row['attempt']+1}: "
                  f"{row.get('performance_exclusion', 'recorded measurement interruption')}" for row in excluded]
    lines += ['', 'Peak RSS is the process resident set, not total model or Metal memory. '
              'Other timing variation has no assigned cause. Machine-state snapshots record available '
              'thermal, power, swap, VM and memory-pressure probes before and after each run; '
              'unavailable probes are marked below.', '', '## Resolved settings', '',
              '| Model | Context | Cache slots | Prefill | Chunk | Sampling T / K / P |',
              '| --- | ---: | ---: | --- | ---: | --- |']
    for model in dict.fromkeys(row['model'] for row in text_rows):
        settings = next((row.get('resolved_settings') for row in text_rows
                         if row['model'] == model and row.get('resolved_settings')), None)
        if not settings:
            continue
        lines.append(f"| {labels[model]} | {settings['context']} | {settings['expert_cache_slots']} | "
                     f"{settings['prefill']} | {settings['prefill_chunk_tokens']} | "
                     f"{settings['temperature']} / {settings['top_k']} / {settings['top_p']} |")
    lines += ['', 'Full resolved runtime settings (including kernel preferences):', '']
    for model in dict.fromkeys(row['model'] for row in text_rows):
        settings = next((row.get('resolved_settings') for row in text_rows
                         if row['model'] == model and row.get('resolved_settings')), None)
        if settings:
            lines += [f"**{labels[model]}**", '', '```json', json.dumps(settings, sort_keys=True, indent=2), '```', '']
    lines += ['', '## Individual text attempts', '',
              'Wall is elapsed harness-attempt time, including before-run probes and '
              'metadata checks. Prefill and decode are CLI intervals, so their sum is '
              'not the complete attempt time.', '',
              '| Model | Attempt | Status / stop | Prompt / generated | Prefill | Decode | tok/s | Wall |',
              '| --- | ---: | --- | --- | ---: | ---: | ---: | ---: |']
    for row in text_rows:
        def number(key):
            return f"{row[key]:.3f}" if key in row else 'unavailable'
        lines.append(f"| {row['label']} | {row['attempt']+1} | {row['status']} / {row.get('stop', 'unavailable')} | "
                     f"{row.get('prompt_tokens', '?')} / {row.get('generated_tokens', '?')} | "
                     f"{number('prefill_seconds')} | {number('decode_seconds')} | {number('tps')} | {number('wall_seconds')} |")
    lines += ['', '## Logical expert I/O (prefill and decode combined)', '',
              '| Model / attempt | Demand records / bytes | Prefetch records / bytes | Exposed wait ms | Slot allocations |',
              '| --- | --- | --- | ---: | ---: |']
    for row in text_rows:
        io = row.get('expert_io', {})
        demand, prefetch = io.get('demand', {}), io.get('prefetch', {})
        if not demand and not prefetch:
            continue
        lines.append(f"| {row['label']} / {row['attempt']+1} | {demand.get('reads', '?')} / {demand.get('bytes', '?')} | "
                     f"{prefetch.get('reads', '?')} / {prefetch.get('bytes', '?')} | "
                     f"{io.get('exposed_prefetch_wait_ms', '?')} | {row.get('allocated_expert_slot_bytes', 0)} |")
    if vision:
        lines += ['', '## Image smoke checks', '', '| Model | Status | Stop |', '| --- | --- | --- |']
        lines += [f"| {row['label']} | {row['status']} | {row.get('stop', 'unavailable')} |" for row in vision]
    lines += ['', '## Machine-state observations', '',
              'These probes do not establish the cause of a timing difference. Memory free '
              'is the system-wide percentage reported by `memory_pressure -Q`. Swap values '
              'come from `vm.swapusage`. VM counters list cumulative system pageins, '
              'pageouts, swapins and swapouts from `vm_stat`, in that order. Each pair '
              'is before / after the attempt.', '',
              '| Model / kind / attempt | Memory free | Swap | Thermal | Power | VM counters |',
              '| --- | --- | --- | --- | --- | --- |']
    for row in rows:
        before = row.get('machine_state_before', {})
        after = row.get('machine_state_after', {})
        pairs = [memory_free(before) + ' / ' + memory_free(after)]
        pairs += [probe(before, name) + ' / ' + probe(after, name)
                  for name in ('swap_usage', 'thermal', 'power')]
        pairs += [vm_counters(before) + ' / ' + vm_counters(after)]
        lines.append(f"| {row['label']} / {row['kind']} / {row['attempt']+1} | "
                     + ' | '.join(pairs) + ' |')
    lines += ['', '## Scope and identity', '',
              'Text checks require the answer to name Paris. Image checks use the supplied '
              'prompt and keywords. Neither test establishes reasoning, tool or general vision '
              'quality. Independent toy and kernel regressions run separately in the serial suite.', '',
              f"Packaged CLI SHA-256: `{report['identity']['cli_sha256']}`.", '',
              f"Sources fingerprint: `{report['identity']['source_sha256']}`.", '',
              f"Packaged shaders fingerprint: `{report['identity'].get('shaders_sha256', 'unavailable')}`.", '',
              f"Text prompt SHA-256: `{report['identity'].get('prompt_sha256', 'unavailable')}`.", '',
              '| Model | Text manifest SHA-256 | Image manifest SHA-256 |',
              '| --- | --- | --- |']
    for model in dict.fromkeys(row['model'] for row in rows):
        manifest = next((row.get('manifest_sha256') for row in rows
                         if row['model'] == model and row.get('manifest_sha256')), 'unavailable')
        image_manifest = next((row.get('vision_manifest_sha256') for row in vision
                               if row['model'] == model and row.get('vision_manifest_sha256')), 'not checked')
        lines.append(f"| {labels[model]} | `{manifest}` | `{image_manifest}` |")
    lines += ['',
              'Only the available Mac was exercised. Other chips and memory capacities are '
              'not hardware-validated by this release.', '',
              'Raw outputs are temporary release artifacts. This sanitized report preserves '
              'all measured decode rates and resolved settings after local cleanup.', '']
    return '\n'.join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--results', type=Path, required=True)
    parser.add_argument('--version', required=True)
    parser.add_argument('--summary', help='accepted for existing release callers')
    args = parser.parse_args()
    if not re.fullmatch(r'\d+\.\d+\.\d+', args.version):
        parser.error('version must be major.minor.patch')
    report = json.loads(args.results.read_text())
    if not report.get('finished') or not report['results']:
        parser.error('the sweep must finish before rendering its summary')
    (ROOT / 'docs/MODEL_VALIDATION.md').write_text(render(report, args.version))
    print('Updated sanitized model validation report')


if __name__ == '__main__':
    main()
