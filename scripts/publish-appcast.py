#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Publish a signed feed without replacing a newer build or engine epoch."""
import argparse
import base64
import json
import os
from pathlib import Path
import re
import subprocess
import xml.etree.ElementTree as ET

SPARKLE = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
REPOSITORY = 'repos/starharbor2491/neutrino-browser'


def feed_policy(data):
    item = ET.fromstring(data).find('channel/item')
    if item is None:
        raise ValueError('Missing appcast item')
    build = int(item.findtext('{' + SPARKLE + '}version', '0'))
    epoch = int(item.findtext('neutrinoSecurityEpoch', '0'))
    if build <= 0 or epoch <= 0:
        raise ValueError('Missing appcast build or security epoch')
    return build, epoch


def api(method, path, body=None, missing=False):
    result = subprocess.run(['gh', 'api', '--method', method, REPOSITORY + path, '--input', '-'],
                            input=json.dumps(body or {}), capture_output=True, text=True)
    if result.returncode:
        if missing and 'HTTP 404' in result.stderr:
            return None
        if 'HTTP 409' in result.stderr or 'HTTP 422' in result.stderr:
            raise FileExistsError('Concurrent feed publication')
        raise RuntimeError('GitHub feed publication failed')
    return json.loads(result.stdout) if result.stdout else None


def publish(channel, data, commit):
    if channel not in ('stable', 'preview') or not re.fullmatch('[0-9a-f]{40}', commit):
        raise ValueError('Invalid publication channel or source commit')
    build, epoch = feed_policy(data)
    if api('GET', '/git/ref/heads/updates', missing=True) is None:
        try:
            api('POST', '/git/refs', {'ref': 'refs/heads/updates', 'sha': commit})
        except FileExistsError:
            if api('GET', '/git/ref/heads/updates', missing=True) is None:
                raise
    path = '/contents/' + channel + '.xml'
    for _ in range(3):
        current = api('GET', path + '?ref=updates', missing=True)
        body = {'message': 'Publish signed Neutrino ' + channel + ' appcast', 'branch': 'updates',
                'content': base64.b64encode(data).decode()}
        if current:
            old_data = base64.b64decode(current['content'], validate=False)
            old_build, old_epoch = feed_policy(old_data)
            if build < old_build:
                return False
            if epoch < old_epoch:
                raise ValueError('Appcast cannot lower the accepted engine security epoch')
            if build == old_build:
                if data != old_data:
                    raise ValueError('An appcast build is immutable')
                return False
            body['sha'] = current['sha']
        try:
            api('PUT', path, body)
            return True
        except FileExistsError:
            continue
    raise RuntimeError('Appcast changed repeatedly during publication; retry publication')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('channel', choices=('stable', 'preview'))
    parser.add_argument('--directory', type=Path, default=Path('release'))
    args = parser.parse_args()
    publish(args.channel, (args.directory / (args.channel + '.xml')).read_bytes(), os.environ['GITHUB_SHA'])
