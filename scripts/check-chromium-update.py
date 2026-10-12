#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Find a common stable CEF SDK, verify upstream archives, and emit candidate pins.

The runtime never downloads executable engines independently. CI builds and tests
an immutable complete app before publishing a new app+engine update.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import urllib.parse
import urllib.request

CDN='https://cef-builds.spotifycdn.com/'
VERSION=re.compile(r'\d+\.\d+\.\d+\+g[0-9a-f]+\+chromium-\d+\.\d+\.\d+\.\d+')
PLATFORMS={'arm64':'macosarm64','x86_64':'macosx64'}

def numbers(value): return tuple(map(int,value.split('.')))

def select(index,current):
    platforms={}
    for arch,platform in PLATFORMS.items():
        versions={}
        for item in index[platform]['versions']:
            version=item['cef_version']
            if item.get('channel')!='stable' or not VERSION.fullmatch(version): continue
            name='cef_binary_'+version+'_'+platform+'.tar.bz2'
            archive=next((f for f in item['files'] if f['type']=='standard' and f['name']==name),None)
            if archive and re.fullmatch('[0-9a-f]{40}',archive['sha1']) and 50*1024**2 <= archive['size'] <= 800*1024**2:
                versions[version]=archive
        platforms[arch]=versions
    common=set.intersection(*(set(v) for v in platforms.values()))
    if not common: raise RuntimeError('No common stable upstream SDK')
    key=lambda v:(numbers(v.split('chromium-')[1]),numbers(v.split('+')[0]))
    latest=max(common,key=key)
    if key(latest)<=key(current['version']): return None
    return latest,{arch:versions[latest] for arch,versions in platforms.items()}

def verified_digest(file):
    sha1=hashlib.sha1();sha256=hashlib.sha256();size=0
    with urllib.request.urlopen(CDN+urllib.parse.quote(file['name']),timeout=60) as response:
        while block:=response.read(1024*1024):
            size+=len(block)
            if size>file['size']: raise RuntimeError('Upstream archive exceeded declared size')
            sha1.update(block);sha256.update(block)
    if size!=file['size'] or sha1.hexdigest()!=file['sha1']: raise RuntimeError('Upstream archive digest/size mismatch')
    return sha256.hexdigest()

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pin',type=Path,default=Path('ChromiumRuntime/cef-version.json'))
    parser.add_argument('--output',type=Path,default=Path('cef-candidate.json'))
    parser.add_argument('--verify-archives',action='store_true')
    args=parser.parse_args()
    with urllib.request.urlopen(CDN+'index.json',timeout=60) as response:
        raw=response.read(16*1024*1024+1)
    if len(raw)>16*1024*1024: raise RuntimeError('Upstream index exceeded limit')
    result=select(json.loads(raw),json.loads(args.pin.read_text()))
    if result is None:
        args.output.write_text(json.dumps({'changed':False})+'\n');print('Pinned CEF is current');return
    version,files=result
    output={'changed':True,'version':version}
    if args.verify_archives:
        output['pin']={'format':1,'version':version,'archives':{arch:{'platform':PLATFORMS[arch],'sha256':verified_digest(file)} for arch,file in files.items()}}
    args.output.write_text(json.dumps(output,indent=2)+'\n')
    print('Stable CEF candidate: '+version)

if __name__=='__main__':main()
