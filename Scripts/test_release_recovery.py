#!/usr/bin/env python3
import argparse
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET
import release_recovery as recovery
from stamp_appcast import stamp, NAMESPACE, SPARKLE, CURRENT_FORMATS
import re


def swift_constant(relative, pattern):
    match = re.search(pattern, (recovery.ROOT / relative).read_text())
    if not match:
        raise AssertionError(f'{pattern} not found in {relative}')
    return int(match.group(1))


class RecoveryToolsTests(unittest.TestCase):
    def test_withdrawal_is_a_plan_until_explicitly_applied(self):
        result = subprocess.run(['python3', str(recovery.ROOT / 'Scripts/release_recovery.py'),
                                 'withdraw', '--withdrawn', '7.0.0', '--known-good', '6.1.0'],
                                capture_output=True, text=True, check=True)
        plan = json.loads(result.stdout)
        self.assertEqual(len(plan['commands']), 2)
        self.assertIn('--prerelease', plan['commands'][0])
        self.assertIn('--latest', plan['commands'][1])
        self.assertNotIn('delete', result.stdout)

    def test_withdrawal_preserves_assets_and_adds_notice_with_safe_arguments(self):
        calls = []
        original = recovery.run
        def fake(args, cwd=None):
            calls.append(args)
            if args[:3] == ['gh', 'release', 'view']:
                return json.dumps(dict(body='Existing notes', isDraft=False, isPrerelease=False))
            if args[:3] == ['gh', 'release', 'download']:
                (Path(args[-1]) / 'appcast.xml').write_text('<rss/>')
            if '--notes-file' in args:
                self.assertIn('Existing notes', Path(args[-1]).read_text())
                self.assertIn('Update withdrawn', Path(args[-1]).read_text())
            return ''
        recovery.run = fake
        try:
            recovery.withdraw(argparse.Namespace(withdrawn='7.0.0', known_good='6.1.0', apply=True, allow_unsigned_legacy_feed=True))
        finally:
            recovery.run = original
        self.assertEqual(len(calls), 5)
        self.assertTrue(all('delete' not in command for command in calls))
        self.assertTrue(all('--repo' in command for command in calls))

    def test_unsigned_destination_is_refused_before_mutation(self):
        calls=[]; original=recovery.run
        def fake(args, cwd=None):
            calls.append(args)
            if args[:3] == ['gh', 'release', 'view']:
                return json.dumps(dict(body='', isDraft=False, isPrerelease=False))
            if args[:3] == ['gh', 'release', 'download']:
                (Path(args[-1])/'appcast.xml').write_text('<rss/>')
            return ''
        recovery.run=fake
        try:
            with self.assertRaisesRegex(ValueError, 'unsigned'):
                recovery.withdraw(argparse.Namespace(withdrawn='7.0.0', known_good='6.1.0', apply=True))
        finally: recovery.run=original
        self.assertFalse(any(c[:3]==['gh','release','edit'] for c in calls))

    def test_invalid_versions_never_mutate(self):
        for bad in ['$(touch /tmp/pwn)', 'v7', '7.0.0; echo x']:
            with self.assertRaises(ValueError): recovery.version(bad)
        with self.assertRaises(ValueError):
            recovery.withdraw(argparse.Namespace(withdrawn='6.1.0', known_good='6.1.0', apply=True))

    def test_recovery_preparation_uses_normal_reverts_and_preserves_history(self):
        with tempfile.TemporaryDirectory(prefix='tuff-recovery-repo-') as tmp:
            root = Path(tmp)
            subprocess.run(['git', 'init', '-q', str(root)], check=True)
            def git(*args):
                return subprocess.check_output(['git', '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', *args], cwd=root, text=True).strip()
            source = root / 'Sources/TUFFModelCatalog/TUFFVersion.swift'
            source.parent.mkdir(parents=True)
            source.write_text('public enum TUFFVersion { public static let current = "6.1.0" }\n')
            (root / 'runtime.txt').write_text('known good\n')
            git('add', '.'); git('commit', '-qm', 'known good'); known = git('rev-parse', 'HEAD')
            (root / 'runtime.txt').write_text('regression\n')
            git('add', '.'); git('commit', '-qm', 'regression'); bad = git('rev-parse', 'HEAD')
            original = recovery.ROOT
            recovery.ROOT = root
            original_run = recovery.run
            recovery.run = lambda args, cwd=None: git(*args[1:]) if args[0] == 'git' else original_run(args, cwd=root)
            git('config', 'user.name', 'Fixture'); git('config', 'user.email', 'fixture@example.invalid')
            try:
                recovery.prepare(argparse.Namespace(known_good=known, withdrawn='7.0.0', version='7.0.1',
                    reason='Restores correct runtime output.', chats_schema=2, app_settings=7, background_settings=1, apply=True))
            finally:
                recovery.ROOT = original; recovery.run = original_run
            self.assertEqual((root / 'runtime.txt').read_text(), 'known good\n')
            self.assertIn('7.0.1', source.read_text())
            self.assertEqual(git('rev-list', '--count', bad + '..HEAD'), '2')
            git('merge-base', '--is-ancestor', bad, 'HEAD')
            manifest = json.loads((root / 'docs/RELEASE_7.0.1_RECOVERY.json').read_text())
            self.assertEqual(manifest['known_good_commit'], known)
            self.assertEqual(manifest['reverted_commits'], [bad])

    def test_declared_data_formats_match_the_schemas_the_app_writes(self):
        # The feed stamp, the updater's compatibility gate and the stores that
        # actually write these files must agree, or a recovery could be offered
        # to a Mac whose data it cannot read.
        written = dict(
            chats=swift_constant('Sources/TUFFApp/Core/State/AppConversationPersistence.swift',
                                 r'static let currentSchemaVersion = (\d+)'),
            app_settings=swift_constant('Sources/TUFFApp/Core/Configuration/MacAppSettings.swift',
                                        r'static let currentVersion = (\d+)'),
            background_settings=swift_constant('Sources/TUFFModelCatalog/TUFFBackgroundServerSettings.swift',
                                               r'static let currentVersion = (\d+)'))
        self.assertEqual(CURRENT_FORMATS, written)
        updater = (recovery.ROOT / 'Sources/TUFFApp/Updater/RecoveryUpdatePolicy.swift').read_text()
        declared = re.search(r'static let current = TUFFDataVersions\(chats: (\d+), appSettings: (\d+), '
                             r'backgroundSettings: (\d+)\)', updater)
        self.assertIsNotNone(declared)
        self.assertEqual(tuple(map(int, declared.groups())),
                         (written['chats'], written['app_settings'], written['background_settings']))

    def test_prepare_updates_the_about_version_of_older_sources(self):
        source = 'public static let fallbackShortVersion = "6.1.0"\n'
        self.assertIn('"7.0.1"', recovery.set_about_version(source, '7.0.1'))
        self.assertIn('"7.0.1"', recovery.set_about_version('static let appVersion = "1.0.0"', '7.0.1'))

    def test_appcast_metadata_retains_signed_enclosure_fields(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'appcast.xml'
            path.write_text(f'<rss xmlns:sparkle="{SPARKLE}"><channel><item><sparkle:version>7.0.1</sparkle:version>'
                            '<enclosure url="https://example.com/app.zip" length="123" sparkle:edSignature="signature"/></item></channel></rss>')
            stamp(path, dict(recovery_version='7.0.1', withdrawn_version='7.0.0', known_good_commit='a'*40,
                             data_formats=dict(chats=2, app_settings=7, background_settings=1)))
            item = ET.parse(path).getroot().find('./channel/item')
            self.assertEqual(item.findtext(f'{{{NAMESPACE}}}recovery'), 'true')
            self.assertEqual(item.find('enclosure').get(f'{{{SPARKLE}}}edSignature'), 'signature')
            self.assertEqual(item.findtext(f'{{{NAMESPACE}}}appSettingsVersion'), '7')


if __name__ == '__main__':
    unittest.main()
