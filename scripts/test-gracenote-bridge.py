"""Offline regression cases for the album-result parser; no SDK or credentials."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('gracenote_bridge', Path(__file__).resolve().parents[1] / 'Resources/Enrichment/gracenote_windows.py')
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)

class AlbumParserTests(unittest.TestCase):
    def test_full_album_preserves_track_edition_and_extended_fields(self):
        xml = '''<ALBUM_RESPONSE><ALBUM ORD="1" LANG="eng"><FULL_RESULT>1</FULL_RESULT><TITLE_OFFICIAL><DISPLAY>Album</DISPLAY></TITLE_OFFICIAL><YEAR>1982</YEAR><LABEL>Test Label</LABEL><TRACK_COUNT>9</TRACK_COUNT><DISC_IN_SET>1</DISC_IN_SET><TOTAL_IN_SET>2</TOTAL_IN_SET><GENRE_LEVEL1>R&amp;B</GENRE_LEVEL1><ARTIST><NAME_OFFICIAL><DISPLAY>Album Artist</DISPLAY></NAME_OFFICIAL><CONTRIBUTOR><ORIGIN_LEVEL3>Indiana</ORIGIN_LEVEL3></CONTRIBUTOR></ARTIST><TRACK_MATCHED>6</TRACK_MATCHED><TRACK><TRACK_NUM>1</TRACK_NUM><TITLE_OFFICIAL><DISPLAY>Other</DISPLAY></TITLE_OFFICIAL></TRACK><TRACK><TRACK_NUM>6</TRACK_NUM><TITLE_OFFICIAL><DISPLAY>Song</DISPLAY></TITLE_OFFICIAL><CREDIT ROLE="Composer"><NAME_OFFICIAL><DISPLAY>Composer A</DISPLAY></NAME_OFFICIAL></CREDIT></TRACK><CONTENT><TYPE>gnsdk_content_image_cover</TYPE><ASSET SIZE="large" DIMENSION="720x720" BYTES="12345"><URL>akamai-b.cdn.cddbp.net/cds/2.0/cover/test.jpg</URL></ASSET></CONTENT></ALBUM></ALBUM_RESPONSE>'''
        values = bridge.parse_candidates(xml, 'Song', serialized_albums={'1':'opaque selected GDO'})
        self.assertEqual(len(values),1)
        item = values[0]; fields = item['metadata']['additionalFields']
        self.assertEqual(item['metadata']['track'],'6'); self.assertEqual(item['metadata']['year'],'1982')
        self.assertEqual(item['metadata']['genre'],'R&B'); self.assertEqual(fields['LABEL'],'Test Label')
        self.assertEqual(fields['TRACKTOTAL'],'9'); self.assertEqual(fields['DISCTOTAL'],'2')
        self.assertEqual(fields['ALBUMARTIST'],'Album Artist'); self.assertEqual(fields['COMPOSER'],'Composer A')
        self.assertEqual(fields['ARTIST_ORIGIN'],'Indiana'); self.assertEqual(fields['LANGUAGE'],'eng')
        self.assertEqual(item['artwork'][0]['width'],720); self.assertTrue(item['fullResult'])
        self.assertEqual(item['sdkData'],'opaque selected GDO')
    def test_same_text_different_release_covers_are_not_merged(self):
        albums = ''.join(f'<ALBUM ORD="{i}"><TITLE>A</TITLE><TRACK><TITLE>Song</TITLE><MATCHED>1</MATCHED></TRACK><CONTENT><TYPE>gnsdk_content_image_cover</TYPE><ASSET DIMENSION="300x300"><URL>akamai-b.cdn.cddbp.net/cds/cover/{i}.jpg</URL></ASSET></CONTENT></ALBUM>' for i in (1,2))
        items = bridge.parse_candidates('<ALBUM_RESPONSE>'+albums+'</ALBUM_RESPONSE>','Song')
        self.assertEqual(len(items),2); self.assertNotEqual(items[0]['id'],items[1]['id'])
    def test_missing_optional_fields_and_unrelated_content(self):
        xml = '<ALBUM_RESPONSE><ALBUM ORD="1"><TITLE>A</TITLE><TRACK><TITLE>Song</TITLE><MATCHED>1</MATCHED></TRACK><CONTENT><TYPE>gnsdk_content_dsp_12t</TYPE><ASSET DIMENSION="720x720"><URL>example.test/not-art.bin</URL></ASSET></CONTENT></ALBUM></ALBUM_RESPONSE>'
        result = bridge.parse_candidates(xml,'Song')[0]
        self.assertEqual(result['artwork'],[]); self.assertFalse(result['fullResult'])
        self.assertNotIn('LABEL',result['metadata']['additionalFields'])
        self.assertNotIn('COMPOSER',result['metadata']['additionalFields'])

if __name__ == '__main__': unittest.main()
