#!/usr/bin/env python3
"""Audit only this repository's tracked source and reachable Git history."""
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def git(*args):
    return subprocess.check_output(['git', '-C', str(ROOT), *args])


def require(condition, message):
    if not condition:
        raise SystemExit('FAIL: ' + message)


def main():
    metadata = json.loads((ROOT / 'release.json').read_text())
    allowed = set(metadata['allowed_public_files'])
    baseline = {item['path']: item['sha256'] for item in metadata['accepted_source_files']}
    overrides = set(metadata['documentation_overrides'])
    require(overrides <= {'README.md'}, 'only README release documentation may override the accepted snapshot')
    tracked = set(git('ls-files', '-z').decode().rstrip('\0').split('\0'))
    require(tracked == allowed, 'tracked source differs from the closed release allowlist')
    for name in sorted(tracked):
        path = ROOT / name
        require(path.is_file() and not path.is_symlink(), 'non-regular source: ' + name)
        data = path.read_bytes()
        if name in baseline and name not in overrides:
            require(hashlib.sha256(data).hexdigest() == baseline[name], 'accepted implementation changed: ' + name)
    require((ROOT / 'VERSION').read_text().strip() == metadata['version'] == '1.5.0', 'unexpected version')
    project = (ROOT / 'ios/FrpClient.xcodeproj/project.pbxproj').read_text()
    require(set(re.findall(r'CURRENT_PROJECT_VERSION = (\d+);', project)) == {'10'}, 'unexpected app/widget Build')
    patterns = [rb'/Users/[A-Za-z0-9_.-]+/', rb'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----',
                rb'gh[pousr]_[A-Za-z0-9_]{30,}', rb'github_pat_[A-Za-z0-9_]{30,}']
    revisions = git('rev-list', '--all').decode().splitlines()
    require(revisions, 'commit the audited candidate before checking history')
    objects = set()
    for revision in revisions:
        rows = git('ls-tree', '-rz', revision).split(b'\0')
        for row in rows:
            if not row:
                continue
            details, raw_name = row.split(b'\t', 1)
            mode, kind, digest = details.decode().split()
            name = raw_name.decode()
            require(name in allowed and kind == 'blob', 'history contains a non-allowlisted file')
            require(mode == ('100755' if name.endswith('.sh') else '100644'), 'unexpected source mode: ' + name)
            if digest in objects:
                continue
            objects.add(digest)
            data = git('cat-file', 'blob', digest)
            require(not any(re.search(pattern, data) for pattern in patterns), 'private source marker in history: ' + name)
    print(json.dumps({'status': 'passed', 'source_files': len(tracked), 'accepted_source_files': len(baseline),
                      'protected_files': len(set(baseline) - overrides), 'commits': len(revisions),
                      'unique_blobs': len(objects), 'scope': 'allowlisted source and reachable Git blobs; no live data read'}))


if __name__ == '__main__':
    main()
