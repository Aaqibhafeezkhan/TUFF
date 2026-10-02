#!/usr/bin/env python3
"""Exercise isolated Sparkle feeds and signatures with an ephemeral Ed25519 key."""
import argparse
import functools
import http.server
import json
from pathlib import Path
import plistlib
import shutil
import socket
import subprocess
import tempfile
import threading
import time
import unittest
import xml.etree.ElementTree as ET
from stamp_appcast import stamp, SPARKLE

ROOT = Path(__file__).resolve().parents[1]
TOOLS = ROOT / '.build/artifacts/sparkle/Sparkle/bin'


def run(args, **kwargs):
    result = subprocess.run(list(map(str, args)), capture_output=True, text=True, **kwargs)
    if result.returncode:
        raise RuntimeError(f'{Path(str(args[0])).name} failed ({result.returncode}): {result.stderr}\n{result.stdout}')
    return result


def check(app):
    if app.resolve() == Path('/Applications/TUFF.app'):
        raise ValueError('personal app is excluded from updater tests')
    with tempfile.TemporaryDirectory(prefix='tuff-updater-fixtures-') as temporary:
        root = Path(temporary)
        key, public = root / 'key', root / 'public'
        run(['swift', ROOT / 'Scripts/Fixtures/updater_key.swift', key, public])
        bundle = root / 'TUFFFixture.app'
        shutil.copytree(app, bundle, symlinks=True)
        info_path = bundle / 'Contents/Info.plist'
        info = plistlib.loads(info_path.read_bytes())
        original = app / 'Contents/MacOS/TUFF'
        original_hash = __import__('hashlib').sha256(original.read_bytes()).hexdigest()
        fixture_id = 'com.rexmhall09.TUFF.updater-fixture'
        info.update(CFBundleIdentifier=fixture_id, CFBundleVersion='7.0.1', CFBundleShortVersionString='7.0.1',
                    SUPublicEDKey=public.read_text(), SUEnableAutomaticChecks=False,
                    SUAutomaticallyUpdate=False, SURequireSignedFeed=True, SUVerifyUpdateBeforeExtraction=True)
        info_path.write_bytes(plistlib.dumps(info))
        run(['codesign', '--force', '--deep', '--sign', '-', bundle])
        archive = root / 'TUFF-fixture.zip'
        run(['ditto', '-c', '-k', '--keepParent', bundle, archive])
        (root / 'TUFF-fixture.md').write_text('Recovery fixture. Restores known-good behavior and keeps local data.\n')
        generator_cache = Path.home() / 'Library/Caches/Sparkle_generate_appcast'
        existing_cache = set(generator_cache.iterdir()) if generator_cache.exists() else set()
        try:
            run([TOOLS / 'generate_appcast', '--ed-key-file', key, '--embed-release-notes', root])
            # Exercise the release shell entrypoint, including macOS Bash 3.2
            # and verification against the public key embedded in the client.
            release_root = root / 'release-root'
            (release_root / 'Scripts').mkdir(parents=True)
            (release_root / 'docs').mkdir()
            (release_root / '.build/artifacts/sparkle').mkdir(parents=True)
            (release_root / '.build/artifacts/sparkle/Sparkle').symlink_to(TOOLS.parent)
            for name in ['generate_update_appcast.sh', 'stamp_appcast.py', 'verify_update.swift']:
                shutil.copy2(ROOT / 'Scripts' / name, release_root / 'Scripts' / name)
            (release_root / 'docs/RELEASE_7.0.1_NOTES.md').write_text('Recovery fixture.\n')
            release_archive = root / 'release-archive'
            release_archive.mkdir()
            release_app = root / 'release-client/TUFF.app'
            shutil.copytree(bundle, release_app, symlinks=True)
            run(['ditto', '-c', '-k', '--keepParent', release_app,
                 release_archive / 'TUFF-v7.0.1-macos-arm64.zip'])
            release_command = ['/bin/bash', release_root / 'Scripts/generate_update_appcast.sh',
                               '7.0.1', release_archive, '--ed-key-file', key]
            run(release_command)
            run(['swift', ROOT / 'Scripts/verify_update.swift', release_archive / 'appcast.xml',
                 release_archive / 'TUFF-v7.0.1-macos-arm64.zip', public])
            (release_archive / 'appcast.xml').unlink()
            other_key, other_public = root / 'release-wrong-key', root / 'release-wrong-public'
            run(['swift', ROOT / 'Scripts/Fixtures/updater_key.swift', other_key, other_public])
            result = subprocess.run(list(map(str, release_command[:-1] + [other_key])), capture_output=True)
            assert result.returncode != 0, 'release generator accepted a key the client does not trust'
            assert not (release_archive / 'appcast.xml').exists(), 'untrusted feed became a release asset'
        finally:
            if generator_cache.exists():
                for generated in set(generator_cache.iterdir()) - existing_cache:
                    if generated.is_dir(): shutil.rmtree(generated)
                    else: generated.unlink()
                if not existing_cache and not list(generator_cache.iterdir()): generator_cache.rmdir()
        feed = root / 'appcast.xml'
        stamp(feed, dict(recovery_version='7.0.1', withdrawn_version='7.0.0', known_good_commit='f'*40,
                         data_formats=dict(chats=2, app_settings=7, background_settings=1)))
        run([TOOLS / 'sign_update', '--ed-key-file', key, feed])
        run([TOOLS / 'sign_update', '--ed-key-file', key, '--verify', feed])
        valid_feed = feed.read_bytes()
        run(['swift', ROOT / 'Scripts/verify_update.swift', feed, archive, public])
        wrong_key, wrong_public = root / 'wrong-key', root / 'wrong-public'
        run(['swift', ROOT / 'Scripts/Fixtures/updater_key.swift', wrong_key, wrong_public])
        wrong = subprocess.run(['swift', str(ROOT / 'Scripts/verify_update.swift'), str(feed), str(archive), str(wrong_public)], capture_output=True)
        assert wrong.returncode != 0, 'client trust verification accepted a different key'
        feed.write_bytes(valid_feed.replace(b'Recovery fixture', b'Tampered fixture'))
        assert feed.read_bytes() != valid_feed
        invalid = subprocess.run([str(TOOLS / 'sign_update'), '--ed-key-file', str(key), '--verify', str(feed)], capture_output=True)
        assert invalid.returncode != 0, 'tampered feed was accepted'
        feed.write_bytes(valid_feed)
        item = ET.parse(feed).getroot().find('./channel/item')
        signature = item.find('enclosure').get(f'{{{SPARKLE}}}edSignature')
        run([TOOLS / 'sign_update', '--ed-key-file', key, '--verify', archive, signature])
        interrupted = root / 'interrupted.zip'
        interrupted.write_bytes(archive.read_bytes()[:4096])
        assert subprocess.run([str(TOOLS / 'sign_update'), '--ed-key-file', str(key), '--verify', str(interrupted), signature], capture_output=True).returncode != 0
        assert __import__('hashlib').sha256(original.read_bytes()).hexdigest() == original_hash
        frameworks = bundle / 'Contents/Frameworks'
        source_headers = ROOT / '.build/checkouts/Sparkle/Sparkle'
        parser, probe = root / 'parser', root / 'probe'
        for output, source in [(parser, 'appcast_parser.m'), (probe, 'updater_probe.m')]:
            run(['clang', '-fobjc-arc', '-DBUILDING_SPARKLE_SOURCES_EXTERNALLY', '-I', source_headers,
                 '-F', frameworks, '-framework', 'Sparkle', '-framework', 'AppKit',
                 '-Wl,-rpath,' + str(frameworks), ROOT / 'Scripts/Fixtures' / source, '-o', output])
        run([parser, feed])
        # The actual updater downloads only fixture feeds. Information probes
        # never start installation or launch the source GUI app.
        handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(root))
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        url = 'http://127.0.0.1:%d/appcast.xml' % server.server_port
        try:
            for installed in ['6.1.0', '7.0.0', '7.0.1']:
                info.update(CFBundleVersion=installed, CFBundleShortVersionString=installed, SUFeedURL=url)
                info_path.write_bytes(plistlib.dumps(info))
                run(['codesign', '--force', '--deep', '--sign', '-', bundle])
                result = run([probe, bundle], timeout=25)
                found = json.loads(result.stdout.strip().splitlines()[-1])
                assert found['found'] == (installed != '7.0.1'), (installed, found)
                if found['found']: assert found['recovery']
            feed.write_bytes(valid_feed.replace(b'Recovery fixture', b'Tampered fixture'))
            assert feed.read_bytes() != valid_feed
            info.update(CFBundleVersion='7.0.0', CFBundleShortVersionString='7.0.0')
            info_path.write_bytes(plistlib.dumps(info)); run(['codesign', '--force', '--deep', '--sign', '-', bundle])
            result = subprocess.run([str(probe), str(bundle)], capture_output=True, text=True, timeout=25)
            assert result.returncode != 0, 'updater accepted a tampered signed feed'
            feed.write_text('invalid XML')
            result = subprocess.run([str(probe), str(bundle)], capture_output=True, text=True, timeout=25)
            assert result.returncode != 0
            info['SUFeedURL'] = url.replace('/appcast.xml', '/missing.xml')
            info_path.write_bytes(plistlib.dumps(info)); run(['codesign', '--force', '--deep', '--sign', '-', bundle])
            assert subprocess.run([str(probe), str(bundle)], capture_output=True, timeout=25).returncode != 0
            feed.write_bytes(valid_feed)
            tree = ET.parse(feed)
            tree.getroot().find('./channel/item/enclosure').set('url', url.replace('/appcast.xml', '/TUFF-fixture.zip'))
            tree.write(feed, encoding='utf-8', xml_declaration=True)
            run([TOOLS / 'sign_update', '--ed-key-file', key, feed])
            info['SUFeedURL'] = url
            info_path.write_bytes(plistlib.dumps(info))
            # Running the fixture helper inside the test host keeps installation
            # staged until the user driver's explicit cancel reply.
            fixture_executable = bundle / 'Contents/MacOS/TUFF'
            shutil.copy2(probe, fixture_executable)
            run(['codesign', '--force', '--deep', '--sign', '-', bundle])
            before = __import__('hashlib').sha256(fixture_executable.read_bytes()).hexdigest()
            interrupted_result = run([fixture_executable, bundle, '--interrupt-install'], timeout=25)
            interrupted_status = json.loads(interrupted_result.stdout.strip().splitlines()[-1])
            assert interrupted_status['cancelled_installation'], interrupted_status
            assert __import__('hashlib').sha256(fixture_executable.read_bytes()).hexdigest() == before
            assert plistlib.loads(info_path.read_bytes())['CFBundleVersion'] == '7.0.0'
            server.shutdown(); server.server_close()
            info['SUFeedURL'] = url
            info_path.write_bytes(plistlib.dumps(info)); run(['codesign', '--force', '--deep', '--sign', '-', bundle])
            assert subprocess.run([str(probe), str(bundle)], capture_output=True, timeout=25).returncode != 0, 'offline probe unexpectedly succeeded'
        finally:
            server.shutdown(); server.server_close()
            # Remove only this fixture's Sparkle preferences and caches.
            subprocess.run(['defaults', 'delete', fixture_id], capture_output=True)
            for relative in ['Library/Caches/' + fixture_id, 'Library/Preferences/' + fixture_id + '.plist']:
                path = Path.home() / relative
                if path.is_dir(): shutil.rmtree(path)
                elif path.exists(): path.unlink()
        assert __import__('hashlib').sha256(original.read_bytes()).hexdigest() == original_hash
        print('Updater fixtures: valid and tampered feed/archive signatures, Sparkle XML metadata, healthy/affected/current versions, feed failures, offline, interrupted archives and cancelled staged installation passed')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', required=True, type=Path)
    check(parser.parse_args().app.resolve())
