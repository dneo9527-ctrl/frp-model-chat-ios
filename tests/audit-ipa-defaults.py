#!/usr/bin/env python3
"""Check blank shipped defaults and the final IPA's closed payload allowlist.

Never reads a user's live configuration, Keychain, or original IPA. It does not
certify Git history or compare against private credentials.
"""
import argparse
import hashlib
import json
import plistlib
import re
import textwrap
import zipfile
from pathlib import Path


def require(condition, reason):
    if not condition:
        raise SystemExit('FAIL: ' + reason)


def audit(ipa, root):
    source = (root / 'ios/FrpClient/FrpcController.swift').read_text(encoding='utf-8')
    match = re.search(r'static let sampleConfig = """\n(.*?)\n    """', source, re.S)
    require(match is not None, 'default TOML declaration missing')
    sample = textwrap.dedent(match.group(1))
    fields = ['serverAddr', 'auth.token', 'secretKey']
    for name in fields:
        value = re.search(r'(?m)^' + re.escape(name) + r'\s*=\s*"([^"\n]*)"\s*$', sample)
        require(value is not None and value.group(1) == '', 'shipped default must be empty: ' + name)
    for name in ['serverAddr', 'token', 'secretKey']:
        require(re.search(r'var ' + name + r' = ""', source) is not None,
                'new profile default must be empty: ' + name)

    require('com.doc.frpmodelchat.configuration' in source, 'independent Keychain service missing')
    require('com.doc.frpclient.configuration' not in source, 'legacy Keychain service must not be queried')
    prefix = 'Payload/FrpClient.app/'
    expected = {prefix + n for n in ['AppIcon60x60@2x.png', 'Assets.car', 'FrpClient', 'Info.plist', 'PkgInfo']}
    widget = prefix + 'PlugIns/ConnectionStatusWidget.appex/'
    expected.update(widget + n for n in ['ConnectionStatusWidget', 'Info.plist'])
    with zipfile.ZipFile(ipa) as archive:
        require(archive.testzip() is None, 'ZIP integrity failure')
        names = archive.namelist()
        require(len(names) == len(set(names)), 'duplicate ZIP entry')
        require(set(names) == expected, 'unexpected payload files; review before distribution')
        markers = [b'/Users/', b'/Volumes/', b'/home/', b'\\Users\\',
                   b'worker-runs', b'software-release-center',
                   b'synthetic-slot-one-token', b'synthetic-slot-two-secret',
                   b'test-token-long-value', b'e2e-token-only', b'chat-fixture-private-prompt', b'chat-fixture-private-answer',
                   b'ui-fixture-only', b'ui-activity-only', b'ActivityAcceptance', b'qwen3-extremely-long-local-model-name']
        for name in names:
            raw = archive.read(name)
            for marker in markers:
                for encoding in ['utf-8', 'utf-16-le', 'utf-16-be']:
                    needle = marker.decode('ascii').encode(encoding)
                    require(needle not in raw, 'private build path or test fixture in payload: ' + name)
        binary = archive.read(prefix + 'FrpClient')
        require(sample.encode('utf-8') in binary, 'final binary does not contain the audited blank defaults')
        for marker in [b'synthetic-slot-one-token', b'synthetic-slot-two-secret', b'test-token-long-value', b'e2e-token-only', b'chat-fixture-private-prompt', b'chat-fixture-private-answer']:
            require(marker not in binary, 'test credential fixture unexpectedly embedded in app')
        info = plistlib.loads(archive.read(prefix + 'Info.plist'))
        require(info['CFBundleShortVersionString'] == (root / 'VERSION').read_text().strip(),
                'IPA version and source VERSION disagree')
        project = (root / 'ios/FrpClient.xcodeproj/project.pbxproj').read_text()
        builds = set(re.findall(r'CURRENT_PROJECT_VERSION = (\d+);', project))
        require(builds == {info['CFBundleVersion']}, 'IPA build and source project disagree')
        require(info['CFBundleIdentifier'] == 'com.doc.frpmodelchat', 'unexpected bundle identifier')
        require(info.get('NSSupportsLiveActivities') is True, 'Live Activities capability missing')
        require(info.get('MinimumOSVersion') == '15.0', 'main app compatibility changed')
        extension = plistlib.loads(archive.read(widget + 'Info.plist'))
        require(extension['CFBundleIdentifier'] == 'com.doc.frpmodelchat.connection-status', 'unexpected widget identity')
        require(extension['CFBundleExecutable'] == 'ConnectionStatusWidget', 'unexpected widget executable')
        require(extension['CFBundlePackageType'] == 'XPC!', 'unexpected widget package type')
        require(extension['NSExtension'] == {'NSExtensionPointIdentifier': 'com.apple.widgetkit-extension'}, 'unexpected extension capabilities')
        require(extension.get('MinimumOSVersion') == '16.2', 'unexpected widget minimum iOS')
        for key in ['CFBundleShortVersionString', 'CFBundleVersion']:
            require(extension[key] == info[key], 'app and widget version mismatch')
        require('UIBackgroundModes' not in extension, 'widget must not add background modes')
    return {
        'status': 'passed', 'version': info['CFBundleShortVersionString'], 'build': info['CFBundleVersion'],
        'sha256': hashlib.sha256(ipa.read_bytes()).hexdigest(), 'bytes': ipa.stat().st_size,
        'bundle_identifier': info['CFBundleIdentifier'],
        'display_name': info['CFBundleDisplayName'],
        'default_fields': {field: 'empty' for field in fields},
        'new_profiles': '3 empty slots; checked by controller regression tests',
        'payload_allowlist': 'exactly 5 app files and 2 widget files; no config, preferences, Keychain, original IPA or test fixtures',
        'binary_defaults': 'exact audited blank TOML literal found',
        'payload_path_scan': 'all entries checked for personal build paths and named test fixtures in UTF-8/UTF-16',
        'scope': 'current default source and final IPA; no live private data read; not an audit of all Git history',
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('ipa', type=Path)
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    result = audit(args.ipa, Path(__file__).resolve().parents[1])
    output = json.dumps(result, ensure_ascii=False, indent=2) + '\n'
    if args.report:
        args.report.write_text(output, encoding='utf-8')
    print(output, end='')


if __name__ == '__main__':
    main()
