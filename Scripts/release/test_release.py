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
    def test_arm_only_app_and_official_nested_architectures(self):
        release.verify_architectures(['arm64'], is_app=True)
        release.verify_architectures(['arm64', 'x86_64'], is_app=False)
        release.verify_architectures(['arm64'], is_app=False)
        for architectures, is_app in [(['arm64', 'x86_64'], True), (['x86_64'], True),
                                      (['x86_64'], False), ([], False), (['arm64', 'i386'], False)]:
            with self.subTest(architectures=architectures, is_app=is_app), self.assertRaises(ValueError):
                release.verify_architectures(architectures, is_app=is_app)

    def test_unreviewed_weak_imports_stop_the_release(self):
        nm = '\n'.join([
            '                 (undefined) weak external _$s10Foundation4DateV2leoiySbAC_ACtFZ (from Foundation)',
            '                 (undefined) weak external _$s7SwiftUI16GlassButtonStyleVACycfC (from SwiftUI)',
            '                 (undefined) external _$s10Foundation4DateV3nowACvgZ (from Foundation)',
            '0000000100188f2c (__TEXT,__text) weak external _$s21BiliVideoCollectionUI4ownN (owned)',
        ])
        names = release.weak_imports(nm)
        self.assertEqual(names, {'_$s10Foundation4DateV2leoiySbAC_ACtFZ', '_$s7SwiftUI16GlassButtonStyleVACycfC'})
        allowed = release.allowed_weak_imports(release.WEAK_IMPORTS.read_text())
        release.verify_weak_imports({'_$s7SwiftUI16GlassButtonStyleVACycfC'}, allowed)
        with self.assertRaises(ValueError):
            release.verify_weak_imports(names, allowed)

    def test_only_production_channel_identity_can_be_released(self):
        production = {'CFBundleIdentifier': release.BUNDLE, 'CFBundleDisplayName': 'BiliKit',
                      'CFBundleIconName': 'AppIcon', 'SUFeedURL': release.FEED}
        release.verify_production_identity(production)
        development = {'CFBundleIdentifier': release.BUNDLE + '.dev', 'CFBundleDisplayName': 'BiliKit Dev',
                       'CFBundleIconName': 'AppIcon-Dev', 'SUFeedURL': ''}
        for key in production:
            with self.subTest(key=key), self.assertRaises(ValueError):
                release.verify_production_identity({**production, key: development[key]})

    def test_ci_requires_all_apple_silicon_jobs(self):
        runs = {'workflow_runs': [{'head_branch': 'main', 'conclusion': 'success',
                                  'jobs_url': 'jobs', 'html_url': 'run'}]}
        jobs = [{'name': f'Build and test ({osname})', 'conclusion': 'success'}
                for osname in ('macos-15', 'macos-26', 'macos-27')]
        with patch.object(release, 'run', side_effect=[json.dumps(runs), json.dumps({'jobs': jobs})]):
            self.assertEqual(release.ci('a' * 40), 'run')
        with patch.object(release, 'run', side_effect=[json.dumps(runs), json.dumps({'jobs': jobs[:2]})]), self.assertRaises(ValueError):
            release.ci('a' * 40)
        jobs[0]['name'] = 'Build and test (macos-15-intel)'
        with patch.object(release, 'run', side_effect=[json.dumps(runs), json.dumps({'jobs': jobs})]), self.assertRaises(ValueError):
            release.ci('a' * 40)

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
                        evidence='current candidate report', real_install=True, apple_silicon_macos15=True,
                        signed_keychain=True, sparkle_failure_matrix=True)
        release.validate_acceptance(evidence, state)
        release.validate_acceptance(evidence | dict(apple_silicon_macos15=False, signed_keychain=False, sparkle_failure_matrix=False), state)
        for change in ({'commit': 'c' * 40}, {'dmg_sha256': 'c' * 64}, {'decision': 'no-go'}, {'reviewer': ''}):
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

    def test_release_notes_accept_only_user_facing_items(self):
        with tempfile.TemporaryDirectory() as directory:
            docs = Path(directory)
            with patch.object(release, 'RELEASE_DOCS', docs):
                with self.assertRaises(ValueError):
                    release.release_notes('9.9.9')
                for text in ('', '# BiliKit 9.9.9\n- 修复\n', '- 修复\n当前尚未发布。\n', '- \n'):
                    (docs / '9.9.9-notes.md').write_text(text)
                    with self.subTest(text=text), self.assertRaises(ValueError):
                        release.release_notes('9.9.9')
                (docs / '9.9.9-notes.md').write_text('\n- 修复甲\n- 修复乙\n\n')
                self.assertEqual(release.release_notes('9.9.9'), '- 修复甲\n- 修复乙\n')

    def test_repository_notes_for_current_version_are_valid(self):
        self.assertTrue(release.release_notes(release.version()[0]))

    def test_release_page_embeds_the_same_notes_once(self):
        with tempfile.TemporaryDirectory() as directory:
            docs = Path(directory)
            with patch.object(release, 'RELEASE_DOCS', docs):
                (docs / 'release-page.md').write_text('BiliKit {version}（{build}）\n\n{notes}\n\n安装说明\n')
                page = release.release_page({'version': '9.9.9', 'build': 12}, '- 修复甲\n')
                self.assertEqual(page, 'BiliKit 9.9.9（12）\n\n- 修复甲\n\n安装说明\n')
                (docs / 'release-page.md').write_text('{notes}{notes}')
                with self.assertRaises(ValueError):
                    release.release_page({'version': '9.9.9', 'build': 12}, '- 修复甲\n')

    def test_candidate_feed_item_embeds_notes_and_requires_apple_silicon(self):
        ns = 'xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"'
        description = '<description sparkle:format="markdown"><![CDATA[- 修复甲\n- 修复乙\n]]></description>'
        hardware = '<sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>'
        notes = '- 修复甲\n- 修复乙\n'
        def item(*parts):
            return release.ET.fromstring(f'<item {ns}>{"".join(parts)}</item>')
        release.validate_release_item(item(description, hardware), notes)
        for parts in ((hardware,), (description,), (description.replace('markdown', 'html'), hardware),
                      (description.replace('修复乙', '修复丙'), hardware),
                      (description, hardware.replace('arm64', 'x86_64'))):
            with self.subTest(parts=parts), self.assertRaises(ValueError):
                release.validate_release_item(item(*parts), notes)

    def test_tap_cask_only_moves_forward_to_the_same_dmg(self):
        def cask(version='1.6.0,14', sha='a' * 64, url=release.CASK_URL):
            return f'cask "bilikit" do\n  version "{version}"\n  sha256 "{sha}"\n\n  {url}\nend\n'
        self.assertEqual(release.bump_cask(cask(), '1.7.0', 15, 'b' * 64), cask('1.7.0,15', 'b' * 64))
        self.assertEqual(release.bump_cask(cask(), '1.6.0', 14, 'a' * 64), cask())
        for text, version, build, sha in ((cask(), '1.5.0', 13, 'b' * 64), (cask(), '1.6.0', 14, 'b' * 64),
                                          (cask(), '1.6.1', 14, 'a' * 64), (cask(url='url "https://example.org/x.dmg"'), '1.7.0', 15, 'b' * 64),
                                          (cask() + '  sha256 "' + 'c' * 64 + '"\n', '1.7.0', 15, 'b' * 64), (cask('1.6.0'), '1.7.0', 15, 'b' * 64)):
            with self.subTest(text=text, build=build, sha=sha), self.assertRaises(ValueError):
                release.bump_cask(text, version, build, sha)

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
