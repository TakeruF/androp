# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 anDrop contributors
"""Conversion must replace stale motion metadata without dropping photo metadata."""
from pathlib import Path
import struct
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Sources'))
import motion_photos as motion


RDF = 'http://www.w3.org/1999/02/22-rdf-syntax-ns#'
PRIVATE = 'https://example.invalid/photo/'
OPLUS = 'http://ns.oplus.com/photos/1.0/camera/'


def segment(marker, data):
    return b'\xff' + bytes([marker]) + struct.pack('!H', len(data) + 2) + data


def packet(xml):
    return segment(0xe1, motion.XMP + xml.encode())


def old_metadata(*, gainmap=False):
    auxiliary = ('<rdf:li><Co:Item I:Semantic="GainMap" I:Mime="image/jpeg" I:Length="12" p:Gain="kept"/></rdf:li>'
                 if gainmap else '')
    return f'''<x:xmpmeta xmlns:x="adobe:ns:meta/" xmlns:rdf="{RDF}"
        xmlns:C="{motion.CAMERA}" xmlns:Co="{motion.CONTAINER}" xmlns:I="{motion.ITEM}"
        xmlns:Op="{OPLUS}" xmlns:p="{PRIVATE}" xmlns:value="https://example.invalid/types/">
      <rdf:RDF><rdf:Description C:MotionPhoto="1" C:MicroVideoOffset="999"
          C:ExposureHint="unchanged" Op:VideoLength="999" p:Creator="original" p:Kind="value:Portrait">
        <C:MotionPhotoPresentationTimestampUs>999</C:MotionPhotoPresentationTimestampUs>
        <Co:Directory><rdf:Seq>
          <rdf:li><Co:Item I:Semantic="Primary" I:Mime="image/jpeg" I:Length="0"/></rdf:li>
          {auxiliary}
          <rdf:li><Co:Item><I:Semantic>MotionPhoto</I:Semantic><I:Mime>video/mp4</I:Mime>
            <I:Length>999</I:Length></Co:Item></rdf:li>
        </rdf:Seq></Co:Directory>
      </rdf:Description></rdf:RDF></x:xmpmeta>'''


class MotionPhotoXMPTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.root = Path(self.folder.name)
        self.image = self.root / 'still.jpg'
        self.video = self.root / 'motion.mp4'
        self.movie = b''.join(struct.pack('!I4s', 8, kind) for kind in (b'ftyp', b'moov', b'mdat'))
        self.video.write_bytes(self.movie)
        self.exif = segment(0xe1, b'Exif\0\0original-exif')
        self.icc = segment(0xe2, b'ICC_PROFILE\0\x01\x01profile-data')
        self.scan = b'\xff\xda\0\x02compressed\xff\0pixels\xff\xd9gainmap-data'

    async def asyncTearDown(self):
        self.folder.cleanup()

    def source(self, *packets, mpf=b''):
        data = b'\xff\xd8' + self.exif + self.icc + mpf + b''.join(packets) + self.scan
        self.image.write_bytes(data)
        return data

    async def test_rewrap_replaces_motion_only_and_rebuilds_single_primary_mpf(self):
        existing_mpf = b'\xff' + motion._mpf(123)  # Marker padding must not hide the old index.
        original = self.source(packet(old_metadata()), mpf=existing_mpf)
        target = self.root / 'updated.MP.jpg'
        await motion.compose(self.image, self.video, target, timestamp=42)
        data = target.read_bytes()
        with target.open('rb') as source:
            packets = motion._jpeg_xmp(source)
        self.assertEqual(len(packets), 1)
        root = ET.fromstring(packets[0])
        self.assertEqual(motion._property(root, motion.CAMERA, 'MotionPhotoPresentationTimestampUs'), '42')
        self.assertEqual(motion._property(root, OPLUS, 'VideoLength'), str(len(self.movie)))
        self.assertEqual(motion._property(root, motion.CAMERA, 'ExposureHint'), 'unchanged')
        self.assertEqual(motion._property(root, PRIVATE, 'Creator'), 'original')
        self.assertEqual(motion._property(root, PRIVATE, 'Kind'), 'value:Portrait')
        self.assertIn(b'xmlns:value="https://example.invalid/types/"', packets[0])
        items = list(root.iter('{' + motion.CONTAINER + '}Item'))
        self.assertEqual([motion._property(item, motion.ITEM, 'Semantic') for item in items],
                         ['Primary', 'MotionPhoto'])
        self.assertEqual(motion._property(items[1], motion.ITEM, 'Length'), str(len(self.movie)))
        self.assertIn(self.exif, data)
        self.assertIn(self.icc, data)
        self.assertEqual(data.count(b'MPF\0'), 1)
        mpf = data.index(b'MPF\0')
        self.assertEqual(struct.unpack_from('!I', data, mpf + 58)[0], len(data) - len(self.movie))
        self.assertTrue(data.endswith(self.scan + self.movie))
        self.assertEqual(self.image.read_bytes(), original)
        self.assertEqual(motion.motion_photo(target).video_length, len(self.movie))

    async def test_huawei_output_removes_stale_android_declarations_but_preserves_photo_xmp(self):
        self.source(packet(old_metadata()))
        target = self.root / 'huawei.jpg'
        await motion.compose(self.image, self.video, target, format='huawei', timestamp=0)
        with target.open('rb') as source:
            packets = motion._jpeg_xmp(source)
        self.assertEqual(len(packets), 1)
        root = ET.fromstring(packets[0])
        self.assertIsNone(motion._property(root, motion.CAMERA, 'MotionPhoto'))
        self.assertIsNone(motion._property(root, OPLUS, 'VideoLength'))
        self.assertEqual(motion._property(root, PRIVATE, 'Creator'), 'original')
        self.assertEqual([motion._property(item, motion.ITEM, 'Semantic')
                          for item in root.iter('{' + motion.CONTAINER + '}Item')], ['Primary'])
        self.assertEqual(motion.motion_photo(target).format, 'huawei')

    async def test_multiple_packets_merge_without_losing_other_descriptions(self):
        extra = f'<rdf:RDF xmlns:rdf="{RDF}" xmlns:q="{PRIVATE}"><rdf:Description q:Rating="5"/></rdf:RDF>'
        self.source(packet(old_metadata()), packet(extra))
        target = self.root / 'merged.jpg'
        await motion.compose(self.image, self.video, target)
        with target.open('rb') as source:
            packets = motion._jpeg_xmp(source)
        self.assertEqual(len(packets), 1)
        self.assertEqual(motion._property(ET.fromstring(packets[0]), PRIVATE, 'Rating'), '5')

    async def test_auxiliary_image_layouts_are_refused_before_writing(self):
        multi = bytearray(motion._mpf(123))
        struct.pack_into('!I', multi, 38, 2)  # NumberOfImages in TIFF's MP index.
        for index, (xmp, mpf) in enumerate(((old_metadata(gainmap=True), motion._mpf(123)),
                                           (old_metadata(), bytes(multi)))):
            with self.subTest(index=index):
                original = self.source(packet(xmp), mpf=mpf)
                target = self.root / f'auxiliary-{index}.jpg'
                with self.assertRaises(motion.MotionPhotoError):
                    await motion.compose(self.image, self.video, target)
                self.assertFalse(target.exists())
                self.assertEqual(self.image.read_bytes(), original)

    async def test_unparseable_or_extended_xmp_fails_before_creating_target(self):
        for index, invalid in enumerate((packet('<broken>'),
                                        segment(0xe1, b'http://ns.adobe.com/xmp/extension/\0unsupported'))):
            with self.subTest(index=index):
                original = self.source(invalid)
                target = self.root / f'failed-{index}.jpg'
                with self.assertRaises(motion.MotionPhotoError):
                    await motion.compose(self.image, self.video, target)
                self.assertFalse(target.exists())
                self.assertEqual(self.image.read_bytes(), original)


if __name__ == '__main__':
    unittest.main()
