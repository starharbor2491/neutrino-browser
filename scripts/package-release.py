#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Create a graphical offline installer; production mode signs/notarizes/staples.

The disk image contains the same Neutrino.app with its selected engine and default
module payloads. Explicit GitHub previews emit a preview update catalog; local
development packages never subscribe to updates or claim consumer acceptance.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import shutil
import subprocess
import tempfile
from disk_images import run as run_disk_image


def digest(path):
    hasher = hashlib.sha256()
    with path.open('rb') as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b''):
            hasher.update(block)
    return hasher.hexdigest()


def checked(command):
    if command[0] == 'hdiutil':
        return run_disk_image(command)
    subprocess.run([str(x) for x in command], check=True)


def notarize(path):
    command = ['xcrun', 'notarytool', 'submit', path, '--wait', '--timeout', '30m']
    profile = os.environ.get('NEUTRINO_NOTARY_PROFILE')
    if profile:
        command += ['--keychain-profile', profile]
    else:
        names = ['NEUTRINO_NOTARY_KEY', 'NEUTRINO_NOTARY_KEY_ID', 'NEUTRINO_NOTARY_ISSUER']
        if not all(os.environ.get(name) for name in names):
            raise RuntimeError('Notarization credentials are required for consumer packaging')
        command += ['--key', os.environ[names[0]], '--key-id', os.environ[names[1]], '--issuer', os.environ[names[2]]]
    checked(command)
    checked(['xcrun', 'stapler', 'staple', path])
    checked(['xcrun', 'stapler', 'validate', path])


def package(app, output, development, allow_webkit_development=False, notarize_preview=False):
    if platform.system() != 'Darwin':
        raise RuntimeError('Disk image packaging requires macOS')
    app = app.resolve(strict=True)
    output.mkdir(parents=True, exist_ok=True)
    metadata = json.loads((app / 'Contents/Resources/Distribution.json').read_text())
    channel = plistlib.loads((app / 'Contents/Info.plist').read_bytes()).get('NeutrinoUpdateChannel', 'local')
    preview = development and channel == 'preview'
    if notarize_preview and not preview:
        raise RuntimeError('Notarized preview packaging requires the preview update channel')
    sealed = not development or notarize_preview
    if metadata['architecture'] != 'arm64':
        raise RuntimeError('Neutrino installers target Apple Silicon only')
    if not metadata['chromium'] and not (development and allow_webkit_development):
        raise RuntimeError('A complete Neutrino installer must contain Blink. WebKit-only packages require explicit development mode.')
    variant = 'AppleSilicon' if metadata['chromium'] else 'WebKit-development-AppleSilicon'
    prefix = 'Neutrino-' + metadata['version'] + '-' + variant
    identity = os.environ.get('NEUTRINO_SIGNING_IDENTITY')
    if sealed:
        if not identity or not identity.startswith('Developer ID Application: '):
            raise RuntimeError('Consumer packaging requires Developer ID Application signing')
        checked(['codesign', '--verify', '--deep', '--strict', '--all-architectures', app])
        with tempfile.TemporaryDirectory(prefix='neutrino-notary-') as temporary:
            archive = Path(temporary) / 'Neutrino.zip'
            checked(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', app, archive])
            # notarytool accepts the archive; staple the submitted application.
            command = ['xcrun', 'notarytool', 'submit', archive, '--wait', '--timeout', '30m']
            profile = os.environ.get('NEUTRINO_NOTARY_PROFILE')
            if profile:
                command += ['--keychain-profile', profile]
            else:
                names = ['NEUTRINO_NOTARY_KEY', 'NEUTRINO_NOTARY_KEY_ID', 'NEUTRINO_NOTARY_ISSUER']
                if not all(os.environ.get(name) for name in names):
                    raise RuntimeError('Notarization credentials are required')
                command += ['--key', os.environ[names[0]], '--key-id', os.environ[names[1]], '--issuer', os.environ[names[2]]]
            checked(command)
        checked(['xcrun', 'stapler', 'staple', app])
        checked(['xcrun', 'stapler', 'validate', app])
        checked(['spctl', '--assess', '--type', 'execute', app])
    dmg = output / (prefix + ('-development' if development and not sealed else '') + '.dmg')
    if dmg.exists():
        dmg.unlink()
    with tempfile.TemporaryDirectory(prefix='neutrino-installer-') as temporary:
        root = Path(temporary)
        checked(['ditto', app, root / 'Neutrino.app'])
        (root / 'Applications').symlink_to('/Applications', target_is_directory=True)
        (root / 'Install Neutrino.txt').write_text(
            'Drag Neutrino to Applications, then open it.\n\n'
            'This is the same Neutrino application with ' + ('Chromium and WebKit' if metadata['chromium'] else 'system WebKit') + '. '
            'Its default modules are included for offline installation. Existing browser data, customized layouts and intentionally removed modules are kept.\n\n'
            + (('GitHub preview: ad-hoc signed and unnotarized. Updates download from the Neutrino GitHub repository and install after you quit.\n' if preview else
                'Local development build: ad-hoc signed and unnotarized. Automatic updates are disabled.\n') if development and not sealed else
               'To install this package from an existing Neutrino app, choose Settings > Browsing engines > Import offline installer. Neutrino verifies the publisher and replaces the app after quitting.\n')
            + 'Source and licenses: https://github.com/starharbor2491/neutrino-browser\n')
        checked(['hdiutil', 'create', '-volname', 'Neutrino', '-srcfolder', root, '-format', 'UDZO', '-ov', dmg])
    if sealed:
        checked(['codesign', '--force', '--timestamp', '--sign', identity, dmg])
        notarize(dmg)
        checked(['spctl', '--assess', '--type', 'open', '--context', 'context:primary-signature', dmg])
    # Archive the final sealed/stapled bundle, never an earlier build. A .app is
    # a directory, so GitHub distributes it as a Finder-expandable ZIP.
    archive = output / (prefix + '.app.zip')
    if archive.exists():
        archive.unlink()
    checked(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', app, archive])
    signature = subprocess.run(['codesign', '-d', '--verbose=4', '--arch', 'arm64', str(app)],
                               check=True, capture_output=True, text=True)
    code_hash = re.search(r'^CDHash=([0-9a-f]{40})$', signature.stderr, re.MULTILINE)
    if not code_hash:
        raise RuntimeError('The application has no Apple Silicon code directory hash')
    evidence = {'release': metadata, 'developerID': sealed, 'notarized': sealed,
                'file': dmg.name, 'bytes': dmg.stat().st_size,
                'sha256': digest(dmg), 'codeDirectoryHash': code_hash.group(1),
                'applicationArchive': {'file': archive.name, 'bytes': archive.stat().st_size, 'sha256': digest(archive)}}
    (output / (prefix + '-package.json')).write_text(json.dumps(evidence, indent=2) + '\n')
    if not development or preview:
        tag = os.environ.get('NEUTRINO_RELEASE_TAG', 'v' + metadata['version'])
        if '/' in tag or '..' in tag or not tag:
            raise ValueError('Invalid release tag')
        asset = {'release': metadata, 'url': 'https://github.com/starharbor2491/neutrino-browser/releases/download/' + tag + '/' + dmg.name,
                 'sha256': evidence['sha256'], 'bytes': evidence['bytes'], 'codeDirectoryHash': evidence['codeDirectoryHash']}
        (output / (prefix + '-catalog-entry.json')).write_text(json.dumps(asset, indent=2) + '\n')
    (output / 'SHA256SUMS').write_text(evidence['sha256'] + '  ' + dmg.name + '\n' + evidence['applicationArchive']['sha256'] + '  ' + archive.name + '\n')
    print(dmg)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, default=Path('dist/Neutrino.app'))
    parser.add_argument('--output', type=Path, default=Path('dist'))
    parser.add_argument('--development', action='store_true')
    parser.add_argument('--allow-webkit-development', action='store_true', help='Allow an explicitly incomplete WebKit-only development package')
    parser.add_argument('--notarize-preview', action='store_true', help='Developer ID sign/notarize a preview without claiming core parity')
    args = parser.parse_args()
    package(args.app, args.output, args.development, args.allow_webkit_development, args.notarize_preview)
