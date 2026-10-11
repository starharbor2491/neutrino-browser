#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
import subprocess
import unittest
from unittest.mock import call, patch
import disk_images


class DiskImageTests(unittest.TestCase):
    @patch('disk_images.time.sleep')
    @patch('disk_images.subprocess.run')
    def test_busy_creation_retries_the_same_verifying_command(self, run, sleep):
        command = ['hdiutil', 'create', '-srcfolder', '/tmp/owned-installer', '-format', 'UDZO', '-ov', '/tmp/owned.dmg']
        run.side_effect = [subprocess.CompletedProcess(command, 16, b'', b'hdiutil: create failed - Resource busy'),
                           subprocess.CompletedProcess(command, 0, b'created', b'')]
        self.assertEqual(disk_images.run(command), b'created')
        self.assertEqual(run.call_args_list, [call(command, timeout=120, capture_output=True)] * 2)
        sleep.assert_called_once_with(2)

    @patch('disk_images.time.sleep')
    @patch('disk_images.subprocess.run')
    def test_bad_images_are_rejected_without_retry(self, run, sleep):
        command = ['hdiutil', 'attach', '/tmp/bad.dmg']
        run.return_value = subprocess.CompletedProcess(command, 1, b'', b'checksum invalid')
        with self.assertRaises(subprocess.CalledProcessError):
            disk_images.run(command)
        run.assert_called_once(); sleep.assert_not_called()

    @patch('disk_images.Path.is_mount', return_value=True)
    @patch('disk_images.time.sleep')
    @patch('disk_images.subprocess.run')
    def test_failed_partial_attach_detaches_only_its_owned_mount(self, run, sleep, mounted):
        command = ['hdiutil', 'attach', '-readonly', '-nobrowse', '-mountpoint', '/tmp/owned-mount', '-plist', '/tmp/app.dmg']
        run.side_effect = [subprocess.CompletedProcess(command, 35, b'', b'Resource temporarily unavailable'),
                           subprocess.CompletedProcess([], 0, b'', b''),
                           subprocess.CompletedProcess(command, 0, b'plist', b'')]
        self.assertEqual(disk_images.run(command), b'plist')
        self.assertEqual(run.call_args_list[1], call(['hdiutil', 'detach', '/tmp/owned-mount'], timeout=60, capture_output=True))
        self.assertEqual(run.call_args_list[2], call(command, timeout=120, capture_output=True))

    @patch('disk_images.time.sleep')
    @patch('disk_images.subprocess.run')
    def test_contention_cannot_retry_indefinitely(self, run, sleep):
        command = ['hdiutil', 'detach', '/tmp/owned-mount']
        run.return_value = subprocess.CompletedProcess(command, 16, b'', b'Resource busy')
        with self.assertRaises(subprocess.CalledProcessError):
            disk_images.run(command)
        self.assertEqual(run.call_count, 5)
        self.assertEqual(sleep.call_count, 4)


if __name__ == '__main__':
    unittest.main()
