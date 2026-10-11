#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Check publisher-recorded core acceptance against the exact installer.

This checks receipt completeness and artifact identity. It does not perform the
manual tests or replace signature, notarization, or installed-app verification.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re

CHECKS = frozenset({
    'onboarding', 'workspaces', 'editor', 'dailyBrowsing', 'passwordsAutofill',
    'blocking', 'extensions', 'protectedStreaming', 'offlineInstaller', 'accessibility',
})


def read_json(path):
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 256 * 1024:
        raise ValueError('Acceptance records must be bounded regular JSON files')
    return json.loads(path.read_text())


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def verify(root, receipt, checkout):
    if not re.fullmatch(r'[a-f0-9]{40}', checkout):
        raise ValueError('Invalid source checkout')
    records = list(root.glob('*-package.json'))
    if len(records) != 1:
        raise ValueError('One complete consumer installer is required')
    package = read_json(records[0])
    name = package.get('file')
    if not isinstance(name, str) or Path(name).name != name or not name.endswith('.dmg'):
        raise ValueError('Invalid installer basename')
    installer = root / name
    release = package.get('release', {})
    if (installer.is_symlink() or not installer.is_file()
            or installer.stat().st_size != package.get('bytes')
            or digest(installer) != package.get('sha256')
            or package.get('developerID') is not True or package.get('notarized') is not True
            or release.get('architecture') != 'arm64' or release.get('chromium') is not True):
        raise ValueError('The exact complete notarized Apple Silicon installer is required')
    if (receipt.get('format') != 1 or receipt.get('sourceCheckout') != checkout
            or receipt.get('installerSHA256') != package['sha256']
            or not isinstance(receipt.get('testedBy'), str) or not receipt['testedBy'].strip()):
        raise ValueError('Core acceptance does not identify this checkout, installer, and tester')
    entries = receipt.get('checks')
    if not isinstance(entries, list) or len(entries) != len(CHECKS):
        raise ValueError('Every core acceptance check is required')
    seen = set()
    for check in entries:
        if (not isinstance(check, dict) or check.get('id') not in CHECKS
                or check['id'] in seen or check.get('result') != 'passed'
                or not isinstance(check.get('evidence'), str)
                or not 10 <= len(check['evidence'].strip()) <= 4096):
            raise ValueError('Core checks require unique passed results and recorded evidence')
        seen.add(check['id'])
    installed = read_json(root / 'installed-smoke.json')
    required = ('passed', 'normalQuit', 'applicationTerminationReplyAccepted',
                'ownedAppProcessesExited', 'installedCopyRemoved', 'externalUserDataKept',
                'chromiumProcessRestartAndNormalQuit')
    if (installed.get('sourceCheckout') != checkout or installed.get('package') != package
            or not all(installed.get(key) is True for key in required)):
        raise ValueError('Installed acceptance and Blink restart must pass for this installer')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', type=Path, required=True)
    parser.add_argument('--receipt', type=Path, required=True)
    parser.add_argument('--checkout', required=True)
    args = parser.parse_args()
    verify(args.directory, read_json(args.receipt), args.checkout)
    print('Exact installer and publisher-recorded core acceptance verified')
