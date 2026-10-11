# SPDX-License-Identifier: MPL-2.0
"""Retry transient DiskImages service contention without relaxing verification."""
from pathlib import Path
import subprocess
import sys
import time


def run(command, timeout=120, attempts=5):
    arguments = [str(value) for value in command]
    if Path(arguments[0]).name != 'hdiutil':
        raise ValueError('Disk image retries are restricted to hdiutil')
    for attempt in range(attempts):
        result = subprocess.run(arguments, timeout=timeout, capture_output=True)
        if result.returncode == 0:
            return result.stdout
        error = result.stderr.decode(errors='replace').lower()
        transient = any(message in error for message in ('resource busy', 'resource temporarily unavailable'))
        if not transient or attempt + 1 == attempts:
            raise subprocess.CalledProcessError(result.returncode, arguments, output=result.stdout, stderr=result.stderr)
        # An unsuccessful attach may still mount its owned volume. Detach that
        # exact mount before retrying; never force a busy volume or skip checks.
        if arguments[1] == 'attach' and '-mountpoint' in arguments:
            mount = Path(arguments[arguments.index('-mountpoint') + 1])
            if mount.is_mount():
                run(['hdiutil', 'detach', mount], timeout=60)
        print('DiskImages service is busy; retrying ' + arguments[1] + '.', file=sys.stderr, flush=True)
        time.sleep(2 * (attempt + 1))
