#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Points the Homebrew cask at a release: its version and the .app.zip checksum.

    python3 scripts/update-cask.py --version 1.0.5-preview.1 --zip release/Neutrino-1.0.5-preview.1-AppleSilicon.app.zip
    python3 scripts/update-cask.py --version 1.0.5-preview.1 --sha256 <hex> --output release/neutrino.rb
"""
import argparse
import hashlib
import re
from pathlib import Path

CASK = Path(__file__).resolve().parent.parent / 'Casks' / 'neutrino.rb'
VERSION = re.compile(r'^\d+\.\d+\.\d+(?:-preview\.\d+)?$')


def updated(text, version, digest):
    if not VERSION.fullmatch(version):
        raise ValueError('Invalid release version: ' + version)
    if not re.fullmatch(r'[0-9a-f]{64}', digest):
        raise ValueError('Invalid SHA-256 checksum')
    text, versions = re.subn(r'^  version "[^"]*"$', f'  version "{version}"', text, count=1, flags=re.M)
    text, digests = re.subn(r'^  sha256 "[0-9a-f]{64}"$', f'  sha256 "{digest}"', text, count=1, flags=re.M)
    if versions != 1 or digests != 1:
        raise ValueError('The cask has no version or sha256 line to update')
    return text


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--version', required=True)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument('--zip', type=Path, help='The release .app.zip; its checksum is computed')
    source.add_argument('--sha256', help='The .app.zip checksum, when the file is elsewhere')
    parser.add_argument('--output', type=Path, default=CASK, help='Where to write the cask (default: Casks/neutrino.rb)')
    args = parser.parse_args()
    if args.zip and args.zip.name != f'Neutrino-{args.version}-AppleSilicon.app.zip':
        raise SystemExit(f'Expected Neutrino-{args.version}-AppleSilicon.app.zip, the name the cask downloads')
    digest = hashlib.sha256(args.zip.read_bytes()).hexdigest() if args.zip else args.sha256.lower()
    args.output.write_text(updated(CASK.read_text(), args.version, digest))
    print(f'{args.output}: Neutrino {args.version}, sha256 {digest}')


if __name__ == '__main__':
    main()
