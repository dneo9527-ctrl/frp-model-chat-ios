#!/usr/bin/env python3
"""Export a closed source allowlist, excluding all local state and build output."""
import argparse
import hashlib
import json
from pathlib import Path
import zipfile

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('output', type=Path)
args = parser.parse_args()
files = [root / name for name in ['README.md', 'LICENSE', 'VERSION', 'build.sh', '.gitignore', 'go/go.mod', 'go/go.sum', 'docs/THIRD-PARTY-NOTICES.txt', 'docs/UPDATE-FEED.md', 'docs/REFINEMENT-1.4.1.md', 'docs/BLACK-THEME-1.4.2.md', 'docs/LIVE-ACTIVITY-1.5.0.md']]
for folder, patterns in {
    'go/frpclib': ['*.go'], 'go/e2e': ['*.go'],
    'ios/FrpClient': ['*.swift', 'Info.plist'],
    'ios/Shared': ['*.swift'],
    'ios/ConnectionStatusWidget': ['*.swift', 'Info.plist'],
    'ios/FrpClient/Assets.xcassets': ['**/*.json', '**/*.png'],
    'ios/FrpClient.xcodeproj': ['project.pbxproj', 'xcshareddata/xcschemes/*.xcscheme'],
    'ios': ['ExportOptions.plist.template'],
    'tests': ['*.swift', '*.sh', '*.py']
}.items():
    for pattern in patterns:
        files.extend((root / folder).glob(pattern))
files = sorted(set(files))
assert all(p.is_file() and not p.is_symlink() for p in files)
args.output.parent.mkdir(parents=True, exist_ok=True)
with zipfile.ZipFile(args.output, 'x', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
    for path in files:
        name = 'FrpModelChat-source/' + str(path.relative_to(root))
        info = zipfile.ZipInfo(name, (2026, 11, 17, 0, 0, 0))
        info.compress_type = zipfile.ZIP_DEFLATED
        info.external_attr = (0o100755 if path.suffix == '.sh' else 0o100644) << 16
        data = path.read_bytes()
        personal_prefix = str(Path.home()) + '/'
        for encoding in ['utf-8', 'utf-16-le', 'utf-16-be']:
            assert personal_prefix.encode(encoding) not in data, 'personal path in source allowlist: ' + name
        archive.writestr(info, data)
with zipfile.ZipFile(args.output) as archive:
    assert archive.testzip() is None
    assert len(archive.namelist()) == len(files)
    assert all(not any(part in name.split('/') for part in ['.git', 'worker-runs', 'verification', 'build', 'Frameworks']) for name in archive.namelist())
print(json.dumps({'status': 'passed', 'files': len(files), 'sha256': hashlib.sha256(args.output.read_bytes()).hexdigest(), 'bytes': args.output.stat().st_size, 'scope': 'closed source allowlist; excludes build, framework, internal docs, reviews, git history and local state'}, indent=2))
