#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Regression checks for upstream selection and integrity boundaries."""
import hashlib
import importlib.util
import io
import unittest
from unittest.mock import patch
from pathlib import Path

spec=importlib.util.spec_from_file_location('cef_updates',Path(__file__).with_name('check-chromium-update.py'))
updates=importlib.util.module_from_spec(spec);spec.loader.exec_module(updates)

def version(number):return f'{number}.0.1+gabcdef0+chromium-{number}.0.8000.1'
def index(versions):
 result={}
 for platform,entries in versions.items():
  result[platform]={'versions':[{'cef_version':version(n),'channel':channel,'files':[{'type':'standard','name':'cef_binary_'+version(n)+'_'+platform+'.tar.bz2','sha1':'a'*40,'size':100*1024**2}]} for n,channel in entries]}
 return result

class Updates(unittest.TestCase):
 def test_only_newer_common_stable_versions_are_selected(self):
  source=index({'macosarm64':[(154,'stable'),(155,'stable'),(156,'beta')],'macosx64':[(154,'stable'),(155,'stable'),(156,'stable')]})
  self.assertEqual(updates.select(source,{'version':version(154)})[0],version(155))
  self.assertIsNone(updates.select(source,{'version':version(155)}))
  self.assertIsNone(updates.select(source,{'version':version(157)}))
 def test_architecture_without_matching_archive_cannot_advance(self):
  source=index({'macosarm64':[(154,'stable'),(155,'stable')],'macosx64':[(154,'stable')]})
  self.assertIsNone(updates.select(source,{'version':version(154)}))
 def test_digest_and_size_are_verified_before_pin_is_written(self):
  data=b'verified SDK';file={'name':'cef.tar.bz2','sha1':hashlib.sha1(data).hexdigest(),'size':len(data)}
  with patch.object(updates.urllib.request,'urlopen',return_value=io.BytesIO(data)):
   self.assertEqual(updates.verified_digest(file),hashlib.sha256(data).hexdigest())
  with patch.object(updates.urllib.request,'urlopen',return_value=io.BytesIO(data)):
   with self.assertRaises(RuntimeError):updates.verified_digest({**file,'sha1':'0'*40})
  with patch.object(updates.urllib.request,'urlopen',return_value=io.BytesIO(data+b'!')):
   with self.assertRaises(RuntimeError):updates.verified_digest(file)

if __name__=='__main__':unittest.main()
