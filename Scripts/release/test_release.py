"""Release safety contracts; no Keychain, signing, network or external mutation."""
import importlib.util
import json
import sys
sys.dont_write_bytecode = True
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('release', Path(__file__).with_name('release.py'))
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseSafetyTests(unittest.TestCase):
    def test_version_ignores_test_target_version(self):
        project = {'objects': {
            'app': {'isa': 'PBXNativeTarget', 'name': 'BiliKitMac', 'buildConfigurationList': 'appList'},
            'tests': {'isa': 'PBXNativeTarget', 'name': 'BiliKitMacTests', 'buildConfigurationList': 'testList'},
            'appList': {'buildConfigurations': ['debug', 'release']},
            'testList': {'buildConfigurations': ['test']},
            'debug': {'buildSettings': {'MARKETING_VERSION': '2.0.0', 'CURRENT_PROJECT_VERSION': '9'}},
            'release': {'buildSettings': {'MARKETING_VERSION': '2.0.0', 'CURRENT_PROJECT_VERSION': '9'}},
            'test': {'buildSettings': {'MARKETING_VERSION': '1.0', 'CURRENT_PROJECT_VERSION': '1'}},
        }}
        with patch.object(release, 'run', return_value=json.dumps(project)):
            self.assertEqual(release.version(), ('2.0.0', 9))
        project['objects']['release']['buildSettings']['CURRENT_PROJECT_VERSION'] = '10'
        with patch.object(release, 'run', return_value=json.dumps(project)), self.assertRaises(ValueError):
            release.version()

    def test_acceptance_must_bind_exact_candidate(self):
        state = {'commit': 'a' * 40, 'assets': {'app.dmg': {'sha256': 'b' * 64}}}
        evidence = dict(commit=state['commit'], dmg_sha256='b' * 64, decision='go', reviewer='maintainer',
                        evidence='current candidate report', real_install=True, intel_macos15=True,
                        signed_keychain=True, sparkle_failure_matrix=True)
        release.validate_acceptance(evidence, state)
        for change in ({'commit': 'c' * 40}, {'dmg_sha256': 'c' * 64}, {'intel_macos15': False},
                       {'sparkle_failure_matrix': False}, {'decision': 'no-go'}, {'reviewer': ''}):
            with self.subTest(change=change), self.assertRaises(ValueError):
                release.validate_acceptance(evidence | change, state)

    def test_rejects_feed_rollback_and_same_build_replacement(self):
        xml = b'<rss><channel><item><s:version xmlns:s="http://www.andymatuschak.org/xml-namespaces/sparkle">5</s:version></item></channel></rss>'
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory)
            state = {'build': 4, 'assets': {'appcast.xml': {'sha256': 'wrong'}}}
            with patch.object(release, 'download', side_effect=lambda url, path: path.write_bytes(xml)), patch.object(release.feed, 'validate_feed'):
                with self.assertRaises(ValueError):
                    release.validate_live_build(out, state)
                state['build'] = 5
                with self.assertRaises(ValueError):
                    release.validate_live_build(out, state)
                state['assets']['appcast.xml']['sha256'] = release.digest(out / 'prepublish-appcast.xml')
                release.validate_live_build(out, state)

    def test_dirty_tree_cannot_freeze(self):
        with patch.object(release, 'run', return_value=' M source.swift'), self.assertRaises(ValueError):
            release.source()

    def test_file_inventory_preserves_symlink_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory)
            (app / 'code').write_bytes(b'original')
            (app / 'alias').symlink_to('code')
            before = release.files(app)
            (app / 'alias').unlink()
            (app / 'alias').write_bytes(b'original')
            self.assertNotEqual(before, release.files(app))


if __name__ == '__main__':
    unittest.main()
