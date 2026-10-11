#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Add compiled app ZIPs extracted from existing release DMGs without rebuilding them."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import tempfile


def run(arguments, **kwargs):
    return subprocess.run(arguments, check=True, capture_output=True, text=True, **kwargs).stdout


def main(tag):
    if platform.system() != 'Darwin':
        raise RuntimeError('Extracting published app bundles requires macOS')
    repository = os.environ.get('GH_REPO', 'starharbor2491/neutrino-browser')
    releases = json.loads(run(['gh', 'api', 'repos/' + repository + '/releases?per_page=100']))
    selected = [r for r in releases if not r['draft'] and (tag == 'all' or r['tag_name'] == tag)]
    if not selected:
        raise ValueError('No matching published release')
    for release in selected:
        names = {asset['name'] for asset in release['assets']}
        for name in sorted(names):
            if not name.endswith('.dmg') or 'x86_64' in name or not re.fullmatch(r'[A-Za-z0-9._-]+', name):
                continue
            archive_name = name.removesuffix('.dmg') + '.app.zip'
            if archive_name in names:
                continue
            with tempfile.TemporaryDirectory(prefix='neutrino-release-backfill-') as temporary:
                root = Path(temporary); mount = root / 'mount'; mount.mkdir()
                run(['gh', 'release', 'download', release['tag_name'], '--repo', repository, '--pattern', name, '--dir', str(root)])
                attached = True
                try:
                    run(['hdiutil', 'attach', '-readonly', '-nobrowse', '-mountpoint', str(mount), str(root / name)])
                    apps = list(mount.glob('*.app'))
                    if len(apps) != 1 or apps[0].is_symlink():
                        raise ValueError('The existing installer must contain exactly one compiled app')
                    run(['codesign', '--verify', '--deep', '--strict', '--all-architectures', str(apps[0])])
                    archive = root / archive_name
                    run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(apps[0]), str(archive)])
                    run(['hdiutil', 'detach', str(mount)]); attached = False
                    hasher = hashlib.sha256()
                    with archive.open('rb') as handle:
                        for block in iter(lambda: handle.read(1024 * 1024), b''):
                            hasher.update(block)
                    checksum = root / (archive_name + '.sha256')
                    checksum.write_text(hasher.hexdigest() + '  ' + archive_name + '\n')
                    run(['gh', 'release', 'upload', release['tag_name'], str(archive), str(checksum), '--repo', repository])
                    print(release['tag_name'] + ': published ' + archive_name, flush=True)
                finally:
                    if attached:
                        run(['hdiutil', 'detach', str(mount)])


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tag', default='all')
    main(parser.parse_args().tag)
