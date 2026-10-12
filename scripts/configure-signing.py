#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Configure optional CI signing without printing credentials; record only availability."""
import base64
import json
import os
from pathlib import Path
import secrets
import subprocess

NAMES = ['NEUTRINO_SIGNING_IDENTITY','NEUTRINO_SIGNING_CERTIFICATE_BASE64','NEUTRINO_SIGNING_CERTIFICATE_PASSWORD','NEUTRINO_NOTARY_KEY_BASE64','NEUTRINO_NOTARY_KEY_ID','NEUTRINO_NOTARY_ISSUER']

def configure():
    directory = Path(os.environ['RUNNER_TEMP'])
    missing = [name for name in NAMES if not os.environ.get(name)]
    available = not missing
    status = {'format':1,'credentialsAvailable':available,'missing':missing}
    (directory / 'neutrino-signing-status.json').write_text(json.dumps(status,indent=2)+'\n')
    with open(os.environ['GITHUB_OUTPUT'],'a') as output:
        output.write('available='+str(available).lower()+'\n')
    if not available:
        with open(os.environ['GITHUB_ENV'],'a') as output:
            output.write('NEUTRINO_SIGNING_IDENTITY=\n')
        print('Developer ID/notarization credentials unavailable: '+', '.join(missing))
        return
    if not os.environ['NEUTRINO_SIGNING_IDENTITY'].startswith('Developer ID Application: '):
        raise RuntimeError('Signing identity must be a Developer ID Application certificate')
    certificate = directory / 'neutrino-signing.p12'
    key = directory / 'neutrino-notary.p8'
    certificate.write_bytes(base64.b64decode(os.environ[NAMES[1]],validate=True));certificate.chmod(0o600)
    key.write_bytes(base64.b64decode(os.environ[NAMES[3]],validate=True));key.chmod(0o600)
    keychain = directory / 'neutrino-signing.keychain-db'
    password=secrets.token_hex(24)
    commands=[['create-keychain','-p',password,str(keychain)],['set-keychain-settings','-lut','21600',str(keychain)],['unlock-keychain','-p',password,str(keychain)],['import',str(certificate),'-P',os.environ[NAMES[2]],'-A','-t','cert','-f','pkcs12','-k',str(keychain)],['set-key-partition-list','-S','apple-tool:,apple:,codesign:','-s','-k',password,str(keychain)],['list-keychains','-d','user','-s',str(keychain),'/Library/Keychains/System.keychain']]
    for command in commands:
        result=subprocess.run(['security',*command],capture_output=True)
        if result.returncode:
            raise RuntimeError('Signing keychain configuration failed at '+command[0])
    with open(os.environ['GITHUB_ENV'],'a') as output:
        output.write('NEUTRINO_NOTARY_KEY='+str(key)+'\n')
    print('Developer ID signing and notarization configured')

if __name__=='__main__': configure()
