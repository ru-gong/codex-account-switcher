#!/usr/bin/env python3
"""Immutable candidates and acceptance-gated distribution, with optional Apple notarization."""
import argparse
import hashlib
import json
import pathlib
import plistlib
import re
import shutil
import subprocess
import tempfile
import zipfile
from privacy_audit import require_clean

VERSION = '0.4.1'
REQUIRED_CHECKS = {'ui', 'keychain', 'switch_continuity', 'restore', 'soak', 'second_mac'}

def release_preflight(identity, notary_profile, acceptance, source_id, distribution='developer-id'):
    if distribution == 'developer-id':
        if not identity or not identity.startswith('Developer ID Application: '):
            raise ValueError('Notarized distribution requires a Developer ID Application identity.')
        result = subprocess.run(['security', 'find-identity', '-v', '-p', 'codesigning'], capture_output=True, text=True, check=True)
        available = re.findall(r'\b[0-9A-Fa-f]{40}\s+"([^"]+)"', result.stdout)
        if identity not in available:
            raise ValueError('Developer ID identity is not available; no release was built.')
        if not notary_profile:
            raise ValueError('Notarized distribution requires a locally configured notarytool profile.')
    elif distribution != 'adhoc':
        raise ValueError('Unknown distribution method.')
    if acceptance is None:
        raise ValueError('Public release requires completed acceptance evidence.')
    evidence = json.loads(pathlib.Path(acceptance).read_text())
    if evidence.get('version') != VERSION or evidence.get('source_id') != source_id or evidence.get('status') != 'GO':
        raise ValueError('Acceptance must approve this exact version and source ID.')
    if any(evidence.get('checks', {}).get(key) != 'PASS' for key in REQUIRED_CHECKS):
        raise ValueError('UI, Keychain, continuity, restore, observation and second-Mac checks must pass.')
    return evidence

def freeze(repo, output):
    subprocess.run(['python3', 'scripts/freeze.py', '--output', str(output)], cwd=repo, check=True)
    return json.loads(output.read_text())

def package(repo, *, release=False, distribution='adhoc', identity=None, notary_profile=None, acceptance=None):
    notarize = release and distribution == 'developer-id'
    approved = None
    if release:
        with tempfile.TemporaryDirectory(prefix='switcher-release-preflight-') as temporary:
            initial = freeze(repo, pathlib.Path(temporary) / 'source-manifest.json')
        approved = release_preflight(identity, notary_profile, acceptance, initial['source_id'], distribution)
    require_clean(repo)
    output = repo / 'dist' / (VERSION + ('-release' if release else ''))
    output.mkdir(parents=True, exist_ok=False)
    anonymous = '/src/codex-account-switcher'
    subprocess.run(['swift', 'build', '-c', 'release', '-Xswiftc', '-gnone',
                    '-Xswiftc', '-debug-prefix-map', '-Xswiftc', f'{repo.resolve()}={anonymous}',
                    '-Xswiftc', '-file-prefix-map', '-Xswiftc', f'{repo.resolve()}={anonymous}'], cwd=repo, check=True)
    app = output / 'CodexAccountSwitcher.app'
    macos = app / 'Contents/MacOS'
    resources = app / 'Contents/Resources'
    macos.mkdir(parents=True)
    resources.mkdir(parents=True)
    shutil.copy2(repo / '.build/release/CodexAccountSwitcher', macos / 'CodexAccountSwitcher')
    shutil.copyfile(repo / 'README.md', resources / 'README.md')
    shutil.copyfile(repo / 'README.en.md', resources / 'README.en.md')
    shutil.copytree(repo / 'docs', resources / 'docs')
    info = {'CFBundleExecutable': 'CodexAccountSwitcher', 'CFBundleIdentifier': 'local.codex-account-switcher',
            'CFBundleName': 'Codex 账号切换台', 'CFBundleDisplayName': 'Codex 账号切换台',
            'CFBundlePackageType': 'APPL', 'CFBundleShortVersionString': VERSION, 'CFBundleVersion': '401',
            'LSMinimumSystemVersion': '14.0', 'LSUIElement': True, 'NSHighResolutionCapable': True,
            'SwitcherReleaseChannel': 'release' if release else 'candidate',
            'NSHumanReadableCopyright': 'Codex Account Switcher, 2026'}
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    manifest_path = resources / 'source-manifest.json'
    manifest = freeze(repo, manifest_path)
    if release and manifest['source_id'] != approved['source_id']:
        raise ValueError('Source changed after acceptance verification; release stopped.')
    cli = output / 'switcherctl'
    shutil.copy2(repo / '.build/release/switcherctl', cli)
    for binary in [macos / 'CodexAccountSwitcher', cli]:
        subprocess.run(['xcrun', 'strip', '-S', str(binary)], check=True)
        require_clean(binary)
    signing = ['codesign', '--force', '--sign', identity if notarize else '-', '--options', 'runtime']
    signing += ['--timestamp'] if notarize else ['--timestamp=none']
    subprocess.run([*signing, '--identifier', 'local.codex-account-switcher.cli', str(cli)], check=True)
    subprocess.run([*signing, str(app)], check=True)
    for artifact in [app, cli]:
        subprocess.run(['codesign', '--verify', '--strict', '--verbose=2', str(artifact)], check=True)
    app_zip = output / f'CodexAccountSwitcher-{VERSION}-macOS-arm64.zip'
    subprocess.run(['ditto', '--norsrc', '--noextattr', '-c', '-k', '--keepParent', str(app), str(app_zip)], check=True)
    if notarize:
        # Local profile holds Apple credentials; never take passwords in source/arguments.
        result = subprocess.run(['xcrun', 'notarytool', 'submit', str(app_zip), '--keychain-profile',
                                 notary_profile, '--wait', '--output-format', 'json'],
                                capture_output=True, text=True, check=True)
        notarization = json.loads(result.stdout)
        if notarization.get('status') != 'Accepted':
            raise ValueError('Apple notarization was not accepted; no release receipt will be written.')
        subprocess.run(['xcrun', 'stapler', 'staple', str(app)], check=True)
        subprocess.run(['xcrun', 'stapler', 'validate', str(app)], check=True)
        subprocess.run(['spctl', '--assess', '--type', 'execute', '--verbose=2', str(app)], check=True)
        app_zip.unlink()  # Only the ZIP just created here is replaced with the stapled app.
        subprocess.run(['ditto', '--norsrc', '--noextattr', '-c', '-k', '--keepParent', str(app), str(app_zip)], check=True)
    if release:
        (output / 'acceptance.json').write_text(json.dumps(approved, ensure_ascii=False, indent=2) + '\n')
    install = (repo / 'docs/分发安装说明.txt').read_text()
    if release:
        install = install.replace('当前 0.4.1 为测试候选，尚未通过完整发布验收。', '本包已通过当前支持范围的发布验收，分发方式见发布回执。')
        install = install.replace('本候选目前仍需验收模式进行未核验账号的首次切换，不适合作为已完成验收的正式版转交用户日常使用。计划对外发布前还要完成另一台 Mac 的安装和功能验证。', '首次使用新账号需按说明完成账号能力核验；不能据此推定未经测试的 Codex 版本兼容。')
    if notarize:
        install = install.replace('本包采用本地 ad-hoc 签名，未使用 Apple Developer ID，也未经过 Apple 公证。无需注册开发者账号即可安装，但首次打开可能被系统拦截。', '本包已使用 Developer ID 签名并通过 Apple 公证。首次打开仍需确认下载来源。')
    with zipfile.ZipFile(app_zip, 'a', compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr('安装说明.txt', install)
    source_zip = output / f'CodexAccountSwitcher-{VERSION}-source.zip'
    with zipfile.ZipFile(source_zip, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
        for relative, expected in sorted(manifest['files'].items()):
            data = (repo / relative).read_bytes()
            if hashlib.sha256(data).hexdigest() != expected:
                raise RuntimeError('Source changed while packaging')
            archive.writestr(f'CodexAccountSwitcher-{VERSION}/{relative}', data)
        archive.writestr(f'CodexAccountSwitcher-{VERSION}/source-manifest.json', manifest_path.read_bytes())
    # The CLI is a development artifact, outside the notarized public download.
    for archive in [app_zip, source_zip]:
        require_clean(archive)
    artifacts = [app_zip]
    (output / 'SHA256SUMS').write_text(''.join(
        f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}\n' for p in artifacts))
    receipt = {'version': VERSION, 'source_id': manifest['source_id'], 'output': str(output.relative_to(repo)),
               'distribution': 'developer-id' if notarize else 'adhoc-unnotarized',
               'status': ('RELEASE_READY' if notarize else 'RELEASE_READY_UNNOTARIZED') if release else 'CANDIDATE_NOT_RELEASED'}
    if notarize:
        receipt['notarization_id'] = notarization['id']
    (output / 'package-receipt.json').write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(receipt, ensure_ascii=False))

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--release', action='store_true')
    parser.add_argument('--distribution', choices=['adhoc', 'developer-id'], default='adhoc')
    parser.add_argument('--identity')
    parser.add_argument('--notary-profile')
    parser.add_argument('--acceptance', type=pathlib.Path)
    args = parser.parse_args()
    try:
        package(pathlib.Path(__file__).resolve().parent.parent, **vars(args))
    except (ValueError, FileExistsError) as error:
        raise SystemExit(str(error))
