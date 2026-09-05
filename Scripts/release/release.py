#!/usr/bin/env python3
"""Local Developer ID release. Secrets stay in Keychain; all subprocesses use argv."""
import argparse
import datetime
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
sys.dont_write_bytecode = True
import tempfile
import urllib.request
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
REPO = 'shiinayane/BiliKit-Mac'
TEAM = '2B3LZ256AG'
BUNDLE = 'com.shiinayane.BiliKit'
IDENTITY = 'Developer ID Application: YANKAI WANG (2B3LZ256AG)'
FEED = 'https://updates.shiinayane.com/appcast.xml'
SPEC = importlib.util.spec_from_file_location('feed', ROOT / 'Updates/cloudflare/feed.py')
feed = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(feed)
CONFIG = json.loads((ROOT / 'Updates/cloudflare/release.json').read_text())


def require(ok, message):
    if not ok:
        raise ValueError(message)


def run(*args, cwd=ROOT):
    return subprocess.check_output([str(a) for a in args], cwd=cwd, stderr=subprocess.STDOUT).decode().strip()


def logged(path, *args, cwd=ROOT):
    print('运行：', args[0], args[1] if len(args) > 1 else '', flush=True)
    with path.open('w') as out:
        subprocess.run([str(a) for a in args], cwd=cwd, stdout=out, stderr=subprocess.STDOUT, check=True)


def save(path, value):
    temporary = path.with_suffix(path.suffix + '.tmp')
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')
    temporary.replace(path)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def download(url, path):
    require(url.startswith('https://'), '只允许 HTTPS')
    with urllib.request.urlopen(url, timeout=60) as response:
        require(response.url.startswith('https://'), '拒绝 HTTP 重定向')
        path.write_bytes(response.read())


def source():
    require(not run('git', 'status', '--porcelain'), '需要干净 worktree')
    return run('git', 'rev-parse', 'HEAD')


def version():
    project = (ROOT / 'BiliKitMac.xcodeproj/project.pbxproj').read_text()
    versions = re.findall(r'MARKETING_VERSION = ([0-9.]+);', project)
    builds = re.findall(r'CURRENT_PROJECT_VERSION = ([0-9]+);', project)
    require(len(versions) == 2 and len(set(versions)) == 1, 'App 版本配置不一致')
    app_builds = [v for v in builds if v != '1']
    require(len(app_builds) == 2 and len(set(app_builds)) == 1, 'App build 配置不一致')
    require(re.fullmatch(r'\d+\.\d+\.\d+', versions[0]), '需要三段版本')
    return versions[0], int(app_builds[0])


def ci(commit):
    runs = json.loads(run('gh', 'api', f'repos/{REPO}/actions/workflows/ci.yml/runs?head_sha={commit}&event=push'))['workflow_runs']
    require(runs and runs[0]['head_branch'] == 'main' and runs[0]['conclusion'] == 'success', '冻结提交必须具有通过的 main push CI')
    jobs = json.loads(run('gh', 'api', runs[0]['jobs_url']))['jobs']
    require(all(any(j['name'] == f'Build and test ({osname})' and j['conclusion'] == 'success' for j in jobs)
                for osname in ('macos-15-intel', 'macos-26')), '缺少双平台 CI 成功证据')
    return runs[0]['html_url']


def releases():
    return json.loads(run('gh', 'api', '--paginate', '--slurp', f'repos/{REPO}/releases?per_page=100'))


def preflight():
    commit = source()
    v, build = version()
    tag = 'v' + v
    require(run('git', 'remote', 'get-url', 'origin') in
            (f'git@github.com:{REPO}.git', f'https://github.com/{REPO}.git'), '错误仓库')
    require(run('git', 'ls-remote', 'origin', 'refs/heads/main').split()[0] == commit, '先合并到 main 并冻结最新提交')
    ci_url = ci(commit)
    for page in releases():
        for release in page:
            require(release['tag_name'] != tag, 'tag 已有 Release；先人工核对历史草稿，不自动删除/覆盖')
    require(not run('git', 'ls-remote', 'origin', 'refs/tags/' + tag), 'tag 已存在；禁止移动')
    require(IDENTITY in run('security', 'find-identity', '-v', '-p', 'codesigning'), '缺少 Developer ID identity')
    run('xcrun', 'notarytool', 'history', '--keychain-profile', 'BiliKit-Notary', '--output-format', 'json')
    require(run('node', '--version') == 'v22.22.3', '使用 Node 22.22.3，确保 native DMG dependency ABI 一致')
    with tempfile.TemporaryDirectory(prefix='bilikit-feed-') as directory:
        old = Path(directory) / 'appcast.xml'
        download(FEED, old)
        feed.validate_feed(old.read_bytes(), CONFIG)
        items = ET.fromstring(old.read_bytes()).findall('channel/item')
        require(build > max([int(i.findtext('s:version', namespaces=feed.NS)) for i in items] or [0]), 'build 必须高于线上全部版本')
    return {'commit': commit, 'version': v, 'build': build, 'tag': tag, 'ci': ci_url,
            'created': datetime.datetime.now(datetime.timezone.utc).isoformat()}


def files(app):
    return {str(p.relative_to(app)): {'link': os.readlink(p)} if p.is_symlink() else {'sha256': digest(p)}
            for p in sorted(app.rglob('*')) if p.is_symlink() or p.is_file()}


def verify_app(app, state, notarized=True):
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    require((info['CFBundleIdentifier'], info['CFBundleShortVersionString'], int(info['CFBundleVersion']), info['LSMinimumSystemVersion']) ==
            (BUNDLE, state['version'], state['build'], '15.0'), 'App 版本/身份/最低系统错误')
    require(info.get('SUPublicEDKey') == CONFIG['publicEDKey'] and info.get('SUFeedURL') == FEED, '更新公钥或 URL 错误')
    require(all(info.get(k) is True for k in ('BiliKitUpdaterEnabled', 'SURequireSignedFeed', 'SUVerifyUpdateBeforeExtraction'))
            and info.get('SUSignedFeedFailureExpirationInterval') == 0, '更新强制验签配置错误')
    run('codesign', '--verify', '--deep', '--strict', app)
    binaries = []
    for path in sorted(app.rglob('*')):
        if path.is_symlink() or not path.is_file() or 'Mach-O' not in run('file', '-b', path):
            continue
        require(set(run('lipo', '-archs', path).split()) == {'arm64', 'x86_64'}, '缺少 Universal slice')
        signature = run('codesign', '-dvv', path)
        require('TeamIdentifier=' + TEAM in signature and 'Authority=' + IDENTITY in signature
                and 'runtime' in signature and 'Timestamp=' in signature, '嵌套签名/runtime/timestamp 错误')
        ent = subprocess.check_output(['codesign', '-d', '--entitlements', ':-', str(path)], stderr=subprocess.DEVNULL)
        values = plistlib.loads(ent) if ent.strip() else {}
        allowed = {'com.apple.application-identifier', 'com.apple.developer.team-identifier', 'com.apple.security.app-sandbox',
                   'com.apple.security.network.client', 'com.apple.security.network.server', 'keychain-access-groups',
                   'com.apple.security.temporary-exception.mach-lookup.global-name'}
        # Sparkle XPC helpers use only their official sandbox/inherit entitlements.
        if path != app / 'Contents/MacOS/BiliKit':
            allowed = {'com.apple.application-identifier'} if path.name == 'Autoupdate' else set()
            if path.name == 'Autoupdate':
                require(values.get('com.apple.application-identifier') == 'org.sparkle-project.Sparkle.Autoupdate', 'Autoupdate identity 错误')
        require(set(values) <= allowed, '未裁决 entitlement')
        binaries.append({'path': str(path.relative_to(app)), 'entitlements': values})
    require(len(binaries) == 6, '固定 Sparkle 版本应有六个 Mach-O；新嵌套代码需复核')
    ent = next(b['entitlements'] for b in binaries if b['path'] == 'Contents/MacOS/BiliKit')
    require(ent.get('keychain-access-groups') == [TEAM + '.' + BUNDLE] and ent.get('com.apple.security.app-sandbox') is True,
            'App Keychain/Sandbox 错误')
    require(ent.get('com.apple.application-identifier') == TEAM + '.' + BUNDLE and ent.get('com.apple.developer.team-identifier') == TEAM, 'App 签名身份错误')
    require(ent.get('com.apple.security.temporary-exception.mach-lookup.global-name') == [BUNDLE + '-spks', BUNDLE + '-spki'], 'Installer XPC 权限错误')
    profile = app / 'Contents/embedded.provisionprofile'
    if profile.exists():
        data = plistlib.loads(subprocess.check_output(['security', 'cms', '-D', '-i', str(profile)], stderr=subprocess.DEVNULL))
        require(data['TeamIdentifier'] == [TEAM] and data['ExpirationDate'] > datetime.datetime.now(), 'profile Team/有效期错误')
        require(data['Entitlements']['com.apple.application-identifier'] in (TEAM + '.*', TEAM + '.' + BUNDLE), 'profile 不允许当前 App')
    if notarized:
        run('xcrun', 'stapler', 'validate', app)
        run('spctl', '--assess', '--type', 'execute', app)
    return binaries


def notarize(path, name, out):
    status = out / (name + '-notary-submit.json')
    if not status.exists():
        # Save submission ID before waiting, so an interrupted wait can resume safely.
        result = json.loads(run('xcrun', 'notarytool', 'submit', path, '--keychain-profile', 'BiliKit-Notary', '--output-format', 'json'))
        save(status, result)
    identifier = json.loads(status.read_text())['id']
    result = json.loads(run('xcrun', 'notarytool', 'wait', identifier, '--keychain-profile', 'BiliKit-Notary', '--output-format', 'json'))
    require(result['status'] == 'Accepted', '公证未 Accepted；查看 submission ID，禁止继续')
    log = out / (name + '-notary-log.json')
    run('xcrun', 'notarytool', 'log', identifier, '--keychain-profile', 'BiliKit-Notary', log)
    require(not json.loads(log.read_text()).get('issues'), '公证有 warning/error，需裁决')
    run('xcrun', 'stapler', 'staple', path)
    run('xcrun', 'stapler', 'validate', path)


def verify_dmg(dmg, app, state, out):
    run('codesign', '--verify', '--strict', dmg)
    signature = run('codesign', '-dvv', dmg)
    require('Authority=' + IDENTITY in signature and 'Timestamp=' in signature, 'DMG 签名身份错误')
    run('xcrun', 'stapler', 'validate', dmg)
    run('spctl', '--assess', '--type', 'open', '--context', 'context:primary-signature', dmg)
    run('hdiutil', 'verify', dmg)
    mount = out / 'mount'
    mount.mkdir(exist_ok=True)
    run('hdiutil', 'attach', '-readonly', '-nobrowse', '-mountpoint', mount, dmg)
    try:
        require({p.name for p in mount.iterdir()} <= {'BiliKit.app', 'Applications', '.DS_Store', '.VolumeIcon.icns', '.background', '.fseventsd'}, 'DMG 包含意外内容')
        require((mount / 'Applications').is_symlink() and os.readlink(mount / 'Applications') == '/Applications', 'Applications 链接错误')
        require(files(mount / 'BiliKit.app') == files(app), 'DMG 内 App 字节/链接不一致')
        verify_app(mount / 'BiliKit.app', state)
    finally:
        run('hdiutil', 'detach', mount)


def prepare(out):
    manifest = out / 'release.json'
    if manifest.exists():
        state = json.loads(manifest.read_text())
        require(source() == state['commit'], '恢复必须使用原冻结提交')
    else:
        state = preflight()
        out.mkdir(parents=True, exist_ok=False)
        save(manifest, state)
    scratch = out / 'work'
    scratch.mkdir(exist_ok=True)
    (scratch / 'tmp').mkdir(exist_ok=True)
    os.environ['TMPDIR'] = str(scratch / 'tmp')
    os.environ['npm_config_cache'] = str(scratch / 'npm-cache')
    archive, app = out / 'BiliKit.xcarchive', out / 'export/BiliKit.app'
    def step(name, action):
        if name not in state:
            action()
            require(source() == state['commit'], '构建期间源码发生变化')
            state[name] = True
            save(manifest, state)
    def gate():
        logged(out / 'gate.log', 'sh', 'Scripts/run-quality-gates.sh', 'app')
    step('gate', gate)
    if 'toolchain' not in state:
        state['toolchain'] = {'xcode': run('xcodebuild', '-version'), 'swift': run('xcrun', 'swift', '--version'), 'macos': run('sw_vers'), 'node': run('node', '--version')}
        save(manifest, state)
    def build_archive():
        require(not archive.exists(), '不复用不完整 Archive；检查日志并创建新候选目录')
        logged(out / 'archive.log', 'xcodebuild', '-quiet', '-project', 'BiliKitMac.xcodeproj', '-scheme', 'BiliKitMac',
               '-configuration', 'Release', '-destination', 'generic/platform=macOS', '-derivedDataPath', scratch / 'DerivedData',
               '-clonedSourcePackagesDirPath', scratch / 'SourcePackages', '-archivePath', archive,
               '-disableAutomaticPackageResolution', '-onlyUsePackageVersionsFromResolvedFile', 'archive')
    step('archive', build_archive)
    step('export', lambda: logged(out / 'export.log', 'xcodebuild', '-exportArchive', '-archivePath', archive,
                                '-exportOptionsPlist', ROOT / 'Scripts/release/ExportOptions.plist', '-exportPath', out / 'export'))
    verify_app(app, state, notarized=False)
    def app_notary():
        zipped = out / 'app-notary.zip'
        if not zipped.exists():
            run('ditto', '-c', '-k', '--keepParent', app, zipped)
        # ZIP receives no ticket; staple the original exported App after acceptance.
        status = out / 'app-notary-submit.json'
        if not status.exists():
            save(status, json.loads(run('xcrun', 'notarytool', 'submit', zipped, '--keychain-profile', 'BiliKit-Notary', '--output-format', 'json')))
        identifier = json.loads(status.read_text())['id']
        result = json.loads(run('xcrun', 'notarytool', 'wait', identifier, '--keychain-profile', 'BiliKit-Notary', '--output-format', 'json'))
        require(result['status'] == 'Accepted', 'App 公证失败')
        log = out / 'app-notary-log.json'
        run('xcrun', 'notarytool', 'log', identifier, '--keychain-profile', 'BiliKit-Notary', log)
        require(not json.loads(log.read_text()).get('issues'), 'App 公证 warning/error')
        run('xcrun', 'stapler', 'staple', app)
    step('app_notary', app_notary)
    save(out / 'app-verification.json', verify_app(app, state))
    save(out / 'app-files.json', files(app))
    staging = out / 'assets'
    staging.mkdir(exist_ok=True)
    dmg = staging / f"BiliKit-{state['version']}-{state['build']}-universal.dmg"
    def make_dmg():
        require(not dmg.exists(), '拒绝覆盖 DMG')
        tool = scratch / 'dmg-tool'
        tool.mkdir(exist_ok=True)
        for name in ('package.json', 'package-lock.json'):
            shutil.copyfile(ROOT / 'Scripts/release/dmg' / name, tool / name)
        logged(out / 'npm.log', 'npm', 'ci', '--no-audit', '--no-fund', cwd=tool)
        logged(out / 'dmg.log', 'node', tool / 'node_modules/create-dmg/cli.js', app, staging, '--no-code-sign', '--no-version-in-filename')
        (staging / 'BiliKit.dmg').rename(dmg)
        run('codesign', '--force', '--sign', IDENTITY, '--timestamp', '--identifier', BUNDLE + '.dmg', dmg)
    step('dmg', make_dmg)
    step('dmg_notary', lambda: notarize(dmg, 'dmg', out))
    verify_dmg(dmg, app, state, out)
    def appcast():
        binary = scratch / 'SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast'
        logged(out / 'appcast.log', binary, '--maximum-deltas', '0', '--download-url-prefix',
               f"https://github.com/{REPO}/releases/download/{state['tag']}/", '--embed-release-notes', staging)
        feed.validate_feed((staging / 'appcast.xml').read_bytes(), CONFIG, staging)
    step('appcast', appcast)
    state['assets'] = {p.name: {'sha256': digest(p), 'bytes': p.stat().st_size} for p in (dmg, staging / 'appcast.xml')}
    (staging / 'SHA256SUMS').write_text(''.join(f"{v['sha256']}  {k}\n" for k, v in state['assets'].items()))
    validate_candidate_assets(out, state)
    state['prepared'] = True
    save(manifest, state)
    print('候选已准备：', out, flush=True)


def validate_candidate_assets(out, state):
    staging = out / 'assets'
    data = (staging / 'appcast.xml').read_bytes()
    feed.validate_feed(data, CONFIG, staging)
    items = ET.fromstring(data).findall('channel/item')
    require(len(items) == 1, '候选 feed 只能包含当前完整包')
    item = items[0]
    require(item.findtext('s:version', namespaces=feed.NS) == str(state['build']) and
            item.findtext('s:shortVersionString', namespaces=feed.NS) == state['version'], 'feed 与冻结版本不一致')
    filename = f"BiliKit-{state['version']}-{state['build']}-universal.dmg"
    require(item.find('enclosure').get('url') == f"https://github.com/{REPO}/releases/download/{state['tag']}/{filename}",
            '候选 feed 与 tag/DMG URL 不一致')
    checksum = ''.join(f"{v['sha256']}  {k}\n" for k, v in state['assets'].items())
    require((staging / 'SHA256SUMS').read_text() == checksum, 'SHA256SUMS 与冻结资产不一致')


def load_prepared(out):
    state = json.loads((out / 'release.json').read_text())
    require(state.get('prepared') and source() == state['commit'], '需要同一干净冻结提交的完整候选')
    ci(state['commit'])
    for name, value in state['assets'].items():
        require(digest(out / 'assets' / name) == value['sha256'], '冻结资产已改变')
    validate_candidate_assets(out, state)
    return state


def draft(out, notes):
    state = load_prepared(out)
    require(notes.is_file(), '缺少发布说明')
    # No clobber or implicit reuse of a pre-existing release/tag.
    for page in releases():
        require(all(r['tag_name'] != state['tag'] for r in page), 'Release 已存在；核对后使用 publish，禁止覆盖')
    require(not run('git', 'ls-remote', 'origin', 'refs/tags/' + state['tag']), 'tag 已存在')
    assets = [out / 'assets' / n for n in (*state['assets'], 'SHA256SUMS')]
    run('gh', 'release', 'create', state['tag'], *assets, '--repo', REPO, '--target', state['commit'],
        '--draft', '--title', f"BiliKit {state['version']}", '--notes-file', notes)
    print('已上传草稿；尚未公开或部署 feed。')


def validate_acceptance(evidence, state):
    require(evidence.get('commit') == state['commit'] and evidence.get('dmg_sha256') == next(v['sha256'] for k, v in state['assets'].items() if k.endswith('.dmg')),
            '验收必须绑定当前候选')
    require(evidence.get('decision') == 'go' and evidence.get('reviewer') and evidence.get('evidence'), '缺少发布裁决与证据')
    require(all(evidence.get(k) is True for k in ('real_install', 'intel_macos15', 'signed_keychain', 'sparkle_failure_matrix')), '发布 Gate 尚未完成；不得用旧候选或 CI 代替')


def validate_live_build(out, state):
    live = out / 'prepublish-appcast.xml'
    download(FEED, live)
    feed.validate_feed(live.read_bytes(), CONFIG)
    items = ET.fromstring(live.read_bytes()).findall('channel/item')
    latest = max([int(i.findtext('s:version', namespaces=feed.NS)) for i in items] or [0])
    require(latest <= state['build'], '线上已有更高 build；禁止回退 feed')
    if latest == state['build']:
        require(digest(live) == state['assets']['appcast.xml']['sha256'], '同 build feed 内容冲突')


def publish(out, acceptance):
    state = load_prepared(out)
    evidence = json.loads(acceptance.read_text())
    validate_acceptance(evidence, state)
    validate_live_build(out, state)
    release = json.loads(run('gh', 'release', 'view', state['tag'], '--repo', REPO, '--json', 'isDraft,targetCommitish,assets'))
    require(release['targetCommitish'] == state['commit'], 'Release 目标提交错误')
    expected = dict(state['assets'])
    expected['SHA256SUMS'] = {'sha256': digest(out / 'assets/SHA256SUMS'), 'bytes': (out / 'assets/SHA256SUMS').stat().st_size}
    require({a['name'] for a in release['assets']} == set(expected), '远端资产集合错误')
    for asset in release['assets']:
        value = expected[asset['name']]
        require(asset['digest'] == 'sha256:' + value['sha256'] and asset['size'] == value['bytes'], '远端草稿资产 hash/长度错误')
    existing_tag = run('git', 'ls-remote', 'origin', 'refs/tags/' + state['tag'])
    require(not existing_tag or existing_tag.split()[0] == state['commit'], 'tag 已被占用；拒绝公开错误源码')
    if release['isDraft']:
        run('gh', 'release', 'edit', state['tag'], '--repo', REPO, '--draft=false', '--prerelease=false', '--latest')
    # Retry after interruption is read/verify only for existing public assets.
    remote_sha = run('git', 'ls-remote', 'origin', 'refs/tags/' + state['tag']).split()[0]
    require(remote_sha == state['commit'], '公开 tag 与源码不一致；停止 feed 部署')
    downloads = out / 'downloads'
    downloads.mkdir(exist_ok=True)
    for name, value in expected.items():
        download(f"https://github.com/{REPO}/releases/download/{state['tag']}/{name}", downloads / name)
        require(digest(downloads / name) == value['sha256'], '匿名下载 hash 错误；停止 feed 部署')
    dmg = next(downloads.glob('*.dmg'))
    verify_dmg(dmg, out / 'export/BiliKit.app', state, out)
    # Never deploy from an arbitrary dirty deployment checkout.
    deployment = out / 'deployment'
    if not deployment.exists():
        shutil.copytree(ROOT / 'Updates/cloudflare', deployment, ignore=shutil.ignore_patterns('node_modules', '.wrangler', 'appcast.xml'))
    shutil.copyfile(downloads / 'appcast.xml', deployment / 'public/appcast.xml')
    logged(out / 'cloudflare-npm.log', 'npm', 'ci', '--no-audit', '--no-fund', cwd=deployment)
    logged(out / 'cloudflare-dry-run.log', 'npm', 'run', 'dry-run', cwd=deployment)
    validate_live_build(out, state)
    logged(out / 'cloudflare-deploy.log', 'npm', 'run', 'deploy', cwd=deployment)
    download(FEED, downloads / 'live-appcast.xml')
    require(digest(downloads / 'live-appcast.xml') == digest(downloads / 'appcast.xml'), '线上 feed 尚未与本次部署一致；检查缓存后复验')
    feed.validate_feed((downloads / 'live-appcast.xml').read_bytes(), CONFIG, downloads)
    save(out / 'published.json', {'tag': state['tag'], 'commit': state['commit'], 'assets': expected, 'feed_sha256': digest(downloads / 'live-appcast.xml')})
    print(f"发布完成：https://github.com/{REPO}/releases/tag/{state['tag']}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['preflight', 'prepare', 'draft', 'publish'])
    parser.add_argument('--output', type=Path)
    parser.add_argument('--notes', type=Path)
    parser.add_argument('--acceptance', type=Path)
    args = parser.parse_args()
    os.environ.setdefault('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer')
    if args.command == 'preflight':
        print(json.dumps(preflight(), indent=2))
        return
    require(args.output is not None, '需要独立 --output 目录')
    out = args.output.resolve()
    require(out != ROOT and ROOT not in out.parents or ROOT / 'docs/_local' in out.parents, '产物只能位于仓库外或 docs/_local')
    if args.command == 'prepare':
        prepare(out)
    elif args.command == 'draft':
        require(args.notes is not None, '需要 --notes')
        draft(out, args.notes.resolve())
    else:
        require(args.acceptance is not None, '需要 --acceptance')
        publish(out, args.acceptance.resolve())


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError, KeyError) as error:
        # Do not dump command output; Apple/account diagnostics remain local.
        sys.exit(f'发布停止：{error}；检查本地阶段日志，修复后从同一候选目录恢复。')
