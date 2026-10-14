#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Sign complete application archives and publish immutable GitHub update URLs.

This is release tooling, never browser runtime. Private keys only enter native
Sparkle tools through a temporary 0600 file, and tool errors are sanitized.
"""
import base64
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET

REPOSITORY = 'starharbor2491/neutrino-browser'
NAMESPACE = 'http://www.andymatuschak.org/xml-namespaces/sparkle'


def signed_appcast(app, archive, output):
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    public = info.get('SUPublicEDKey')
    receipt = {'enabled': False, 'framework': '2.10.0', 'legacyBridge': True}
    if not public:
        receipt['reason'] = 'Publisher Ed25519 key is not configured; verified legacy GitHub updates remain active.'
        (output / 'sparkle-status.json').write_text(json.dumps(receipt, indent=2) + '\n')
        return receipt
    private = os.environ.get('NEUTRINO_SPARKLE_PRIVATE_KEY', '').strip()
    if not private or len(base64.b64decode(private, validate=True)) != 32:
        raise ValueError('Sparkle publication requires the matching persistent 32-byte private seed secret')
    tools = list(Path('.build/artifacts').rglob('bin/sign_update'))
    if len(tools) != 1:
        raise ValueError('Expected the checksum-pinned Sparkle signing tools')
    tool = tools[0]
    with tempfile.TemporaryDirectory(prefix='neutrino-sparkle-') as directory:
        key = Path(directory) / 'key'
        key.write_text(private + '\n'); key.chmod(0o600)
        def run(command):
            result = subprocess.run(command, capture_output=True, text=True)
            if result.returncode:
                raise RuntimeError('Sparkle signing or verification failed; no feed was published')
            return result.stdout.strip()
        # Native Sparkle derives the public key and keeps the seed in the CI
        # runner's ephemeral Keychain. Verify it against the sealed host key.
        generate = tool.with_name('generate_keys')
        run([str(generate), '--account', 'org.neutrino.browser.release', '-f', str(key)])
        if run([str(generate), '--account', 'org.neutrino.browser.release', '-p']) != public:
            raise ValueError('Sparkle private seed does not match the application public key')
        signature = run([str(tool), '--ed-key-file', str(key), '-p', str(archive)])
        if len(base64.b64decode(signature, validate=True)) != 64:
            raise ValueError('Invalid Sparkle archive signature')
        run([str(tool), '--ed-key-file', str(key), '--verify', str(archive), signature])
        channel = info['NeutrinoUpdateChannel']
        if channel not in ('stable', 'preview'):
            raise ValueError('Appcast requires a published channel')
        version = info['CFBundleShortVersionString']
        tag = os.environ.get('NEUTRINO_RELEASE_TAG', 'v' + version)
        if not re.fullmatch(r'v\d+\.\d+\.\d+(?:-preview\.\d+)?', tag):
            raise ValueError('Invalid Sparkle release tag')
        ET.register_namespace('sparkle', NAMESPACE)
        rss = ET.Element('rss', {'version': '2.0'})
        feed = ET.SubElement(rss, 'channel')
        ET.SubElement(feed, 'title').text = 'Neutrino ' + channel
        item = ET.SubElement(feed, 'item')
        ET.SubElement(item, 'title').text = 'Neutrino ' + version
        ET.SubElement(item, 'link').text = 'https://github.com/' + REPOSITORY + '/releases/tag/' + tag
        release = json.loads((app / 'Contents/Resources/Distribution.json').read_text())
        ET.SubElement(item, 'neutrinoSecurityEpoch').text = str(release['securityEpoch'])
        for name, value in [('version', info['CFBundleVersion']), ('shortVersionString', version), ('minimumSystemVersion', info['LSMinimumSystemVersion']), ('hardwareRequirements', 'arm64')]:
            ET.SubElement(item, '{' + NAMESPACE + '}' + name).text = value
        ET.SubElement(item, 'enclosure', {'url': 'https://github.com/' + REPOSITORY + '/releases/download/' + tag + '/' + archive.name, 'length': str(archive.stat().st_size), 'type': 'application/octet-stream', '{' + NAMESPACE + '}edSignature': signature})
        appcast = output / (channel + '.xml')
        ET.indent(rss)
        appcast.write_bytes(ET.tostring(rss, encoding='utf-8', xml_declaration=True))
        run([str(tool), '--ed-key-file', str(key), str(appcast)])
        run([str(tool), '--ed-key-file', str(key), '--verify', str(appcast)])
        receipt = {'enabled': True, 'framework': '2.10.0', 'signedFeed': True, 'signedArchive': True, 'channel': channel, 'build': info['CFBundleVersion'], 'legacyBridge': True}
    (output / 'sparkle-status.json').write_text(json.dumps(receipt, indent=2) + '\n')
    return receipt
