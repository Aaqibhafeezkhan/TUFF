#!/usr/bin/env python3
"""Model-free checks against an assembled TUFF app; never launch its GUI."""
import argparse
import plistlib
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def check(app):
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    version = re.search(r'static let current\s*=\s*"([^"]+)"',
                        (ROOT / 'Sources/TUFFModelCatalog/TUFFVersion.swift').read_text())[1]
    assert info['CFBundleVersion'] == info['CFBundleShortVersionString'] == version
    assert info['SURequireSignedFeed'] is True and info['SUVerifyUpdateBeforeExtraction'] is True
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    cli = app / 'Contents/Resources/bin/tuff'
    assert subprocess.check_output([str(cli), '--version'], text=True).strip() == f'tuff {version}'
    assert 'tuff prompt' in subprocess.check_output([str(cli), '--help'], text=True)
    # One engine executable serves every role, picked by the name it starts under.
    main = app / 'Contents/MacOS/TUFF'
    for link in ['MacOS/TUFFDecodeService', 'Resources/bin/TUFFCLI', 'Resources/bin/TUFFServer']:
        path = app / 'Contents' / link
        assert path.is_symlink() and path.resolve() == main.resolve(), link
    for name in ['TUFFCLI', 'TUFFServer']:
        usage = subprocess.check_output([str(app / 'Contents/Resources/bin' / name), '--help'], text=True)
        assert f'usage: {name}' in usage, name
    for name in ['tuff', 'TUFFRepack']:
        assert not (app / 'Contents/Resources/bin' / name).is_symlink(), name
    agent = app / 'Contents/Library/LaunchAgents' / (info['CFBundleIdentifier'] + '.server.plist')
    job = plistlib.loads(agent.read_bytes())
    assert job['BundleProgram'] == 'Contents/Resources/bin/TUFFServer'
    assert job['ProgramArguments'] == ['TUFFServer', '--background']
    assert job['RunAtLoad'] and job['KeepAlive'] == {'SuccessfulExit': False}
    for name in ['TUFF_TUFFEngine.bundle', 'TUFF_TUFFAppCore.bundle', 'SwiftMath_SwiftMath.bundle']:
        assert (app / 'Contents/Resources' / name).is_dir(), name
    with tempfile.TemporaryDirectory(prefix='tuff-package-mismatch-') as tmp:
        result = subprocess.run([str(ROOT / 'Scripts/package_app.sh'), '0.0.0', tmp], capture_output=True, text=True)
        assert result.returncode == 64 and 'disagrees' in result.stderr
        assert not list(Path(tmp).iterdir()), 'version mismatch must fail before writing artifacts'
    print(f'Packaged TUFF {version}: signature, version, CLI, roles, agent, signed-feed policy and resources passed')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', required=True, type=Path)
    check(parser.parse_args().app.resolve())
