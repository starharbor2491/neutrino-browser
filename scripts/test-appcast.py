#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Feed publication regressions: immutable builds, epoch floors, concurrent writes."""
import base64
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('publisher', Path(__file__).with_name('publish-appcast.py'))
publisher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publisher)
def feed(build, epoch):
    return f'<rss xmlns:sparkle="{publisher.SPARKLE}"><channel><item><sparkle:version>{build}</sparkle:version><neutrinoSecurityEpoch>{epoch}</neutrinoSecurityEpoch></item></channel></rss>'.encode()
def current(build, epoch):
    return {'sha':'existing', 'content':base64.b64encode(feed(build,epoch)).decode()}

class PublicationTests(unittest.TestCase):
    def test_same_build_is_immutable_and_older_build_is_skipped(self):
        with patch.object(publisher,'api',side_effect=[{},current(5,149)]):
            self.assertFalse(publisher.publish('preview',feed(4,148),'a'*40))
        with patch.object(publisher,'api',side_effect=[{},current(5,149)]):
            with self.assertRaisesRegex(ValueError,'immutable'):
                publisher.publish('preview',feed(5,150),'a'*40)
    def test_epoch_cannot_go_back_on_a_newer_build(self):
        with patch.object(publisher,'api',side_effect=[{},current(5,149)]):
            with self.assertRaisesRegex(ValueError,'security epoch'):
                publisher.publish('stable',feed(6,148),'a'*40)
    def test_conflict_rereads_before_overwriting_a_newer_feed(self):
        with patch.object(publisher,'api',side_effect=[{},current(5,149),FileExistsError(),current(7,150)]) as api:
            self.assertFalse(publisher.publish('preview',feed(6,149),'a'*40))
            self.assertEqual(api.call_count,4)
    def test_new_branch_is_created_at_the_source_commit_and_existing_sha_is_used(self):
        with patch.object(publisher,'api',side_effect=[None,{},current(5,149),{}]) as api:
            self.assertTrue(publisher.publish('preview',feed(6,150),'a'*40))
            self.assertEqual(api.call_args_list[1].args[2]['sha'],'a'*40)
            self.assertEqual(api.call_args_list[3].args[2]['sha'],'existing')
    def test_unsigned_missing_policy_and_unknown_channel_are_rejected(self):
        for data in [b'<rss/>',feed(0,149),feed(5,0)]:
            with self.assertRaises(ValueError):publisher.feed_policy(data)
        with self.assertRaises(ValueError):publisher.publish('latest',feed(5,149),'a'*40)

if __name__=='__main__':unittest.main()
