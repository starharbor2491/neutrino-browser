#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('core_acceptance', Path(__file__).with_name('core-acceptance.py'))
acceptance = importlib.util.module_from_spec(spec)
spec.loader.exec_module(acceptance)


class CoreAcceptanceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / 'Neutrino.dmg').write_bytes(b'installer fixture')
        self.checkout = 'a' * 40
        self.package = {'file': 'Neutrino.dmg', 'bytes': 17, 'sha256': acceptance.digest(self.root / 'Neutrino.dmg'),
                        'developerID': True, 'notarized': True, 'release': {'architecture': 'arm64', 'chromium': True}}
        (self.root / 'Neutrino-package.json').write_text(json.dumps(self.package))
        self.installed = {'sourceCheckout': self.checkout, 'package': self.package}
        for gate in ('passed', 'normalQuit', 'applicationTerminationReplyAccepted', 'ownedAppProcessesExited',
                     'installedCopyRemoved', 'externalUserDataKept', 'chromiumProcessRestartAndNormalQuit'):
            self.installed[gate] = True
        self.write_installed()
        self.receipt = {'format': 1, 'sourceCheckout': self.checkout, 'installerSHA256': self.package['sha256'],
                        'testedBy': 'Test fixture', 'checks': [{'id': key, 'result': 'passed', 'evidence': 'Recorded test fixture only'} for key in sorted(acceptance.CHECKS)]}

    def write_installed(self):
        (self.root / 'installed-smoke.json').write_text(json.dumps(self.installed))

    def verify(self, receipt=None):
        acceptance.verify(self.root, receipt or self.receipt, self.checkout)

    def test_complete_receipt_for_exact_installer(self):
        self.verify()

    def test_skipped_streaming_cannot_pass(self):
        next(check for check in self.receipt['checks'] if check['id'] == 'protectedStreaming')['result'] = 'skipped'
        with self.assertRaises(ValueError): self.verify()

    def test_duplicate_and_missing_checks_cannot_pass(self):
        self.receipt['checks'][0] = copy.deepcopy(self.receipt['checks'][1])
        with self.assertRaises(ValueError): self.verify()

    def test_changed_installer_cannot_reuse_acceptance(self):
        (self.root / 'Neutrino.dmg').write_bytes(b'different fixture')
        with self.assertRaises(ValueError): self.verify()

    def test_other_checkout_cannot_reuse_acceptance(self):
        self.receipt['sourceCheckout'] = 'b' * 40
        with self.assertRaises(ValueError): self.verify()

    def test_watchdog_or_missing_restart_cannot_pass(self):
        self.installed['chromiumProcessRestartAndNormalQuit'] = False
        self.write_installed()
        with self.assertRaises(ValueError): self.verify()


if __name__ == '__main__': unittest.main()
