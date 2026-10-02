#!/usr/bin/env python3
"""Plan or apply a TUFF withdrawal and prepare a newer recovery with normal reverts."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import tempfile
import sys

ROOT = Path(__file__).resolve().parents[1]
REPO = 'rexmhall09/TUFF'
VERSION = re.compile(r'^v?(\d+)\.(\d+)\.(\d+)$')


def version(value):
    match = VERSION.fullmatch(value)
    if not match:
        raise ValueError('expected a dotted numeric release version')
    return tuple(map(int, match.groups()))


def set_about_version(source, newer):
    """Clone builds read the About version from a constant; 6.x sources named it
    fallbackShortVersion, before TUFFVersion.current existed."""
    return re.sub(r'(static let (?:appVersion|fallbackShortVersion)\s*=\s*)"[^"]+"',
                  lambda match: match.group(1) + '"' + newer + '"', source)


def run(args, cwd=ROOT):
    return subprocess.check_output(args, cwd=cwd, text=True).strip()


def withdraw(args):
    if version(args.known_good) == version(args.withdrawn):
        raise ValueError('known-good release must differ from the withdrawn release')
    bad, good = 'v' + args.withdrawn.lstrip('v'), 'v' + args.known_good.lstrip('v')
    commands = [ ['gh', 'release', 'edit', bad, '--repo', REPO, '--prerelease', '--latest=false'],
                 ['gh', 'release', 'edit', good, '--repo', REPO, '--latest'] ]
    if not args.apply:
        print(json.dumps({'commands': commands, 'notice': f'{bad} withdrawn; use {good} until recovery is published.'}, indent=2))
        return
    releases = {tag: json.loads(run(['gh', 'release', 'view', tag, '--repo', REPO,
                                   '--json', 'body,isDraft,isPrerelease'])) for tag in (bad, good)}
    if releases[good]['isDraft'] or releases[good]['isPrerelease'] or releases[bad]['isDraft']:
        raise ValueError('withdrawal requires published releases and a stable known-good release')
    notice = f'Update withdrawn: {bad} has a regression. Use {good} until a newer recovery is published. Chats, settings and models should be kept.'
    notes = releases[bad]['body']
    if notice not in notes:
        notes = notice + '\n\n' + notes
    with tempfile.TemporaryDirectory(prefix='tuff-withdraw-') as tmp:
        run(['gh', 'release', 'download', good, '--repo', REPO, '--pattern', 'appcast.xml', '--dir', tmp])
        feed = Path(tmp) / 'appcast.xml'
        if b'sparkle-signatures:' not in feed.read_bytes():
            if not getattr(args, 'allow_unsigned_legacy_feed', False):
                raise ValueError('known-good feed is unsigned; publish a newer signed recovery first, or explicitly use --allow-unsigned-legacy-feed for a fail-closed temporary withdrawal')
            print('Warning: signed-feed clients will reject this legacy feed. Publish a newer signed recovery promptly; manual recovery remains available.', file=sys.stderr)
        else:
            run(['swift', str(ROOT / 'Scripts/verify_update.swift'), str(feed), '-', str(ROOT / 'Config/UpdateSigningPublicKey.txt')])
        body = Path(tmp) / 'notes.md'
        body.write_text(notes + '\n')
        # Stop defective downloads first. No tag or asset is removed or replaced.
        run(commands[0] + ['--notes-file', str(body)])
        run(commands[1])


def prepare(args):
    newer = args.version.lstrip('v')
    if version(newer) <= version(args.withdrawn):
        raise ValueError('recovery version must be newer than the affected build')
    if run(['git', 'status', '--porcelain']):
        raise ValueError('prepare recovery from a clean checkout; preserve unrelated work separately')
    known = run(['git', 'rev-parse', '--verify', args.known_good + '^{commit}'])
    subprocess.check_call(['git', 'merge-base', '--is-ancestor', known, 'HEAD'], cwd=ROOT)
    commits = run(['git', 'rev-list', '--first-parent', known + '..HEAD']).splitlines()
    if not commits:
        raise ValueError('there are no changes to revert')
    candidate = run(['git', 'rev-parse', 'HEAD'])
    # Recovery transport and data-preservation guards must survive reverting
    # runtime commits. Record this small retained surface for human review.
    recovery_paths = ['Sources/TUFFApp/Updater', 'Sources/TUFFApp/Core/Configuration/MacAppSettings.swift',
                      'Scripts/package_app.sh', 'Scripts/generate_update_appcast.sh', 'Scripts/stamp_appcast.py',
                      'Scripts/release_recovery.py', 'Scripts/check_app_version.rb', 'Tests/TUFFAppUpdater',
                      'Scripts/test_updater_fixtures.py', 'Scripts/verify_update.swift', 'Scripts/Fixtures', 'docs/RELEASE_RECOVERY.md',
                      '.github/workflows/release-withdrawal.yml']
    retained = [p for p in recovery_paths if run(['git', 'ls-tree', '--name-only', candidate, '--', p])]
    provenance = dict(known_good_commit=known, reverted_commits=commits, retained_recovery_paths=retained,
                      withdrawn_version=args.withdrawn.lstrip('v'), recovery_version=newer,
                      data_formats=dict(chats=args.chats_schema, app_settings=args.app_settings,
                                        background_settings=args.background_settings))
    if not args.apply:
        print(json.dumps(provenance, indent=2))
        return
    for commit in commits:
        parents = run(['git', 'rev-list', '--parents', '-n', '1', commit]).split()
        command = ['git', 'revert', '--no-edit']
        if len(parents) > 2:
            command += ['-m', '1']
        subprocess.check_call(command + [commit], cwd=ROOT)
    if retained:
        subprocess.check_call(['git', 'restore', '--source', candidate, '--', *retained], cwd=ROOT)
    source = ROOT / 'Sources/TUFFModelCatalog/TUFFVersion.swift'
    source.parent.mkdir(parents=True, exist_ok=True)
    source.write_text('import Foundation\n\npublic enum TUFFVersion {\n    public static let current = "' + newer + '"\n}\n')
    notes = ROOT / 'docs' / f'RELEASE_{newer}_NOTES.md'
    notes.parent.mkdir(parents=True, exist_ok=True)
    notes.write_text(f'# TUFF {newer} recovery\n\n{args.reason}\n\nRestores runtime code from {known}. '
                     f'Replaces affected TUFF {args.withdrawn.lstrip("v")} with a newer version. '
                     'Chats, settings and model installations are kept. Data compatibility is checked before installation.\n')
    manifest = ROOT / 'docs' / f'RELEASE_{newer}_RECOVERY.json'
    manifest.write_text(json.dumps(provenance, indent=2, sort_keys=True) + '\n')
    # Older known-good sources may still keep the About version locally.
    about = ROOT / 'Sources/TUFFApp/MacPresentation/AboutPanelPresentation.swift'
    if about.exists():
        about.write_text(set_about_version(about.read_text(), newer))
    stage = [str(source), str(notes), str(manifest), *retained]
    if about.exists(): stage.append(str(about))
    subprocess.check_call(['git', 'add', *stage], cwd=ROOT)
    subprocess.check_call(['git', 'commit', '-m', f'Prepare TUFF {newer} recovery from {known[:12]}'], cwd=ROOT)
    print('Local recovery prepared. Run checks, model qualification and review before pushing or signing.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='operation', required=True)
    w = sub.add_parser('withdraw')
    w.add_argument('--withdrawn', required=True)
    w.add_argument('--known-good', required=True)
    w.add_argument('--apply', action='store_true', help='mutate GitHub releases; default only prints the plan')
    w.add_argument('--allow-unsigned-legacy-feed', action='store_true',
                   help='explicit temporary withdrawal to a legacy feed; signed-feed clients fail closed until a newer recovery is published')
    p = sub.add_parser('prepare')
    p.add_argument('--known-good', required=True, help='explicit ancestor commit')
    p.add_argument('--withdrawn', required=True)
    p.add_argument('--version', required=True)
    p.add_argument('--reason', required=True, help='regression and restored behavior')
    for name in ('chats-schema', 'app-settings', 'background-settings'):
        p.add_argument('--' + name, type=int, required=True, help='format version readable by the known-good source')
    p.add_argument('--apply', action='store_true', help='create local revert and recovery commits')
    args = parser.parse_args()
    if args.operation == 'withdraw': withdraw(args)
    else:
        if min(args.chats_schema, args.app_settings, args.background_settings) < 1:
            parser.error('supported data-format versions must be positive')
        prepare(args)


if __name__ == '__main__':
    main()
