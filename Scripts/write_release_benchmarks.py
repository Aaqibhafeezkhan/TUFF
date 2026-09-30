#!/usr/bin/env python3
"""Publish a sanitized summary of validate_release_models.py results to local docs."""
import argparse
import datetime
import html
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parent.parent
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--results', type=Path, required=True)
p.add_argument('--version', required=True)
p.add_argument('--summary', required=True,
               help='one sentence on what the release changed, for the site')
a = p.parse_args()
if not re.fullmatch(r'\d+\.\d+\.\d+', a.version):
    p.error('version must be major.minor.patch')
r = json.loads(a.results.read_text())
paris = [x for x in r['results'] if x['kind'] == 'paris']
vision = [x for x in r['results'] if x['kind'] == 'vision']
photos_skipped = r.get('photo_checks') == 'skipped'
if not r.get('finished') or not paris or not (vision or photos_skipped):
    p.error('the sweep must finish before rendering its summary')
reruns = []
for key, cases in [('completion_checks', paris), ('vision_completion_checks', vision)]:
    for completion in r.get(key, []):
        if completion.get('passed'):
            if completion['cli_sha256'] != r['identity']['cli_sha256']:
                p.error('completion runner differs from the sweep')
            original = next(x for x in cases if x['model'] == completion['model'])
            original.update(completion, status='passed')
            reruns.append((key, original['label']))
models = list(dict.fromkeys(x['model'] for x in paris))
rows = [max((x for x in paris if x['model'] == name), key=lambda x: x.get('tps', -1)) for name in models]
date = datetime.datetime.fromtimestamp(r['started'], datetime.timezone.utc).date().isoformat()
passes = sum(x['status'] == 'passed' for x in paris)
vision_passes = sum(x['status'] == 'passed' for x in vision)
repeat = r['identity']['repeat']
method = ('One fresh process per model' if repeat == 1 else f'Best of {repeat} fresh processes per model')
intro = (f'TUFF {a.version}, measured {date} on a 16 GB M2 MacBook Air. {method}, '
         'answering `What is the capital of France?` with a 4,096-token context, '
         'seed 20260721, and a 128-token output cap (256 for MiniMax M2.7). Decode speed excludes model loading '
         'and prefill; prefill includes the first-use weight checks. '
         f'{passes}/{len(paris)} runs named Paris. These short responses are smoke tests, '
         'not a sustained-throughput or model-quality comparison. Host load and filesystem '
         'caching can affect the timings.')
lines = ['| Model | Decode | Prefill | Peak RSS |', '| --- | ---: | ---: | ---: |']
for x in rows:
    if 'tps' in x:
        lines.append(f"| {x['label']} | {x['tps']:.2f} tok/s | {x['prefill_seconds']:.2f} s | {x.get('peak_rss_bytes', 0)/1048576:.0f} MiB |")
    else:
        lines.append(f"| {x['label']} | {x['status']} | — | — |")
table = '\n'.join(lines)
paris_reruns = [label for key, label in reruns if key == 'completion_checks']
vision_reruns = [label for key, label in reruns if key == 'vision_completion_checks']
rerun_text = (f"{', '.join(paris_reruns)} needed a longer completion rerun; the completed rerun is shown. "
              if paris_reruns else '')
vision_text = '' if not vision else (f'The same packaged runner was tested with one local photo on all {len(vision)} '
               f'image-compatible models, with a 512-token cap. {vision_passes}/{len(vision)} responses passed the glasses-and-towel '
               'keyword smoke check, with responses also reviewed manually. '
               + (f"{', '.join(vision_reruns)} needed a completion rerun. " if vision_reruns else '')
               + 'This is a single-image check, not a general vision accuracy score. '
               'The photo and raw responses are kept out of the repository.')
usage = ('```sh\npython3 Scripts/validate_release_models.py \\\n  --app dist/v'+a.version+'-release-public/TUFF.app \\\n  --model-root "$HOME/Library/Application Support/TUFF/Models" \\\n  '+('--image /path/to/photo.jpeg' if vision else '--text-only')+' \\\n  --output benchmark-results/release-validation\n```')
section = ('### Benchmarks\n\n'+intro+'\n\n'+table+'\n\n'
           'Peak RSS is the process resident set reported by macOS, not total model or Metal memory.'
           + (' ' + rerun_text.rstrip() if rerun_text else '') + '\n\n'
           +(vision_text+'\n\n' if vision_text else '')+'Reproduce the sweep with:\n\n'+usage+'\n\n'
           'The harness saves each command, response, timing, model manifest hash, and runner identity; '
           '`--resume` refuses changed inputs. See [the release validation report](docs/MODEL_VALIDATION.md) '
           'for per-model status and [the runner report](docs/QWEN38_RUNNER_PERFORMANCE.md) '
           'for the separate preprocessing comparison.\n\n')
readme = ROOT/'README.md'
text, count = re.subn(r'### Benchmarks\n.*?(?=#### What v4\.0\.0 changed about decode)', lambda _: section,
                     readme.read_text(), count=1, flags=re.S)
if count != 1:
    p.error('README benchmark section not found')
readme.write_text(text)
report = ['# TUFF '+a.version+' model validation', '', intro, '', table]
if vision:
    report += ['', '## Photo smoke checks', '', vision_text, '', '| Model | Status |', '| --- | --- |']
    report += [f"| {x['label']} | {x['status']} |" for x in vision]
report += ['', '## Reproduction', '', usage, '', f"Packaged CLI SHA-256: `{r['identity']['cli_sha256']}`.", '', f"Sources fingerprint: `{r['identity']['source_sha256']}`.", '', f'Raw evidence is retained locally under `{a.results.parent.name}/`. The fingerprint identifies the compiled source tree; the recorded benchmark base commit may predate the release commit.', '']
(ROOT/'docs/MODEL_VALIDATION.md').write_text('\n'.join(report))
tr = ''.join('<tr><td>'+html.escape(x['label'])+'</td><td>'+f"{x['tps']:.2f} tok/s</td><td>{x['prefill_seconds']:.2f} s</td></tr>" for x in rows if 'tps' in x)
block = ('<!-- release-benchmarks:start -->\n<section class="benchmarks">\n'
         f'<h2>Version {a.version}</h2>\n'
         '<p>'+html.escape(a.summary)+'</p>\n'
         f'<h3>Local model check</h3><p>{html.escape(intro.replace("`", ""))}</p>\n'
         '<div style="overflow-x:auto"><table style="width:100%;text-align:left;border-spacing:0 10px"><thead><tr><th>Model</th><th>Decode</th><th>Prefill</th></tr></thead><tbody>'+tr+'</tbody></table></div>\n'
         +('<p>'+html.escape(vision_text)+'</p>\n' if vision_text else '')+
         '<p><a href="https://github.com/rexmhall09/TUFF/blob/main/docs/MODEL_VALIDATION.md">Validation details and reproduction script</a></p>\n'
         '</section>\n<!-- release-benchmarks:end -->\n')
site = ROOT/'site/index.html'
text = site.read_text()
if '<!-- release-benchmarks:start -->' in text:
    text = re.sub(r'<!-- release-benchmarks:start -->.*?<!-- release-benchmarks:end -->\n?', lambda _: block, text, flags=re.S)
else:
    text = text.replace('  <footer>', block+'\n  <footer>', 1)
site.write_text(text)
print(f'Updated README, site, and sanitized report: {passes}/{len(paris)} Paris, '
      + (f'{vision_passes}/{len(vision)} photo checks' if vision else 'photo checks skipped'))
