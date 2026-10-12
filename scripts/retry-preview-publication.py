#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Retry the source-declared preview when publication failed or was not dispatched."""
import json
import os
from pathlib import Path
import re
import subprocess


def api(path):
    result=subprocess.run(['gh','api',path],capture_output=True,text=True)
    if result.returncode: raise RuntimeError('Cannot inspect GitHub publication state; refusing a duplicate dispatch')
    return json.loads(result.stdout)

def published(value):
    if os.environ.get('GITHUB_OUTPUT'):
        with open(os.environ['GITHUB_OUTPUT'],'a') as output:output.write('published='+str(value).lower()+'\n')

def main():
    repository=os.environ['GH_REPO']
    if repository!='starharbor2491/neutrino-browser':raise RuntimeError('Unexpected update publisher')
    version=Path('PREVIEW_VERSION').read_text().strip()
    if not re.fullmatch(r'\d+\.\d+\.\d+-preview\.\d+',version):raise RuntimeError('Invalid preview version')
    releases=api(f'repos/{repository}/releases?per_page=100')
    released=next((r for r in releases if r['tag_name']=='v'+version and not r['draft']),None)
    if released:
        names={asset['name'] for asset in released['assets']}
        if {'catalog.json','SHA256SUMS','installed-smoke.json'}<=names and any(n.endswith('.app.zip') for n in names) and any(n.endswith('.dmg') for n in names):
            published(True);print('Current preview is published');return
        raise RuntimeError('Release exists with incomplete assets; publisher must repair it before continuing')
    runs=api(f'repos/{repository}/actions/workflows/development-release.yml/runs?branch=main&per_page=100')['workflow_runs']
    published(False)
    if any(r['status']!='completed' for r in runs):
        print('Current preview publication is already running');return
    result=subprocess.run(['gh','workflow','run','development-release.yml','--ref','main','-f','version='+version,'-f','publish=true'],capture_output=True)
    if result.returncode:raise RuntimeError('Could not retry preview publication')
    print('Dispatched publication retry for '+version)

if __name__=='__main__':main()
