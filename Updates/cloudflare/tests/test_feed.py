import base64
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

from feed import validate_feed


class FeedTests(unittest.TestCase):
    def signed_feed(self, url=None, empty=False):
        # Test keys live only in this subprocess's memory. No production key or Keychain access.
        source = r'''
const {generateKeyPairSync, sign} = require('node:crypto');
const {publicKey, privateKey} = generateKeyPairSync('ed25519');
const archive = Buffer.from('test archive bytes');
const url = process.argv[1];
let xml = Buffer.from(`<?xml version="1.0"?><rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><sparkle:version>2</sparkle:version><sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion><enclosure url="${url}" length="${archive.length}" sparkle:edSignature="${sign(null, archive, privateKey).toString('base64')}" /></item></channel></rss>\n`);
if (process.argv[2] === 'empty') xml = Buffer.from('<?xml version="1.0"?><rss version="2.0"><channel /></rss>\n');
const envelope = `<!-- sparkle-signatures:\nedSignature: ${sign(null, xml, privateKey).toString('base64')}\nlength: ${xml.length}\n-->\n`;
process.stdout.write(JSON.stringify({
  key: publicKey.export({format:'der',type:'spki'}).subarray(-32).toString('base64'),
  feed: Buffer.concat([xml, Buffer.from(envelope)]).toString('base64')
}));
'''
        result = subprocess.run([
            "node", "-e", source,
            url or "https://github.com/shiinayane/BiliKit-Mac/releases/download/v1.0.0-build.2/BiliKit-2.dmg",
            "empty" if empty else "full",
        ], check=True, capture_output=True, text=True)
        fixture = json.loads(result.stdout)
        return base64.b64decode(fixture["feed"]), {
            "publicEDKey": fixture["key"],
            "feedURL": "https://updates.shiinayane.com/appcast.xml",
        }

    def test_valid_feed_and_archive_signatures(self):
        data, config = self.signed_feed()
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            (path / "BiliKit-2.dmg").write_bytes(b"test archive bytes")
            self.assertEqual(validate_feed(data, config, path), 1)
            (path / "BiliKit-2.dmg").write_bytes(b"fake archive bytes")
            with self.assertRaises(ValueError):
                validate_feed(data, config, path)

    def test_feed_tampering_is_rejected(self):
        data, config = self.signed_feed()
        with self.assertRaises(ValueError):
            validate_feed(data.replace(b"<sparkle:version>2", b"<sparkle:version>3"), config)

    def test_unsigned_feed_and_trailing_content_are_rejected(self):
        data, config = self.signed_feed()
        for invalid in [data.split(b"<!-- sparkle-signatures:")[0], data + b"extra"]:
            with self.assertRaises(ValueError):
                validate_feed(invalid, config)

    def test_wrong_public_key_is_rejected(self):
        data, _ = self.signed_feed()
        _, other_config = self.signed_feed()
        with self.assertRaises(ValueError):
            validate_feed(data, other_config)

    def test_signed_feed_cannot_publish_disallowed_asset(self):
        for url in [
            "https://github.com/shiinayane/BiliKit-Mac/releases/download/untagged-123/BiliKit-2.dmg",
            "https://github.com/other/BiliKit-Mac/releases/download/v2/BiliKit-2.dmg",
            "https://updates.shiinayane.com/BiliKit-2.dmg",
            "http://github.com/shiinayane/BiliKit-Mac/releases/download/v2/BiliKit-2.dmg",
        ]:
            data, config = self.signed_feed(url)
            with self.assertRaises(ValueError):
                validate_feed(data, config)

    def test_signed_empty_feed_can_pause_offering_updates(self):
        data, config = self.signed_feed(empty=True)
        self.assertEqual(validate_feed(data, config), 0)
