# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 anDrop contributors
import asyncio
import hashlib
import json
from pathlib import Path
import plistlib
import struct
import sys
import tempfile
import unittest
import zipfile
from unittest.mock import AsyncMock, Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Sources'))
import motion_photos as motion


def box(kind, payload=b''):
    return struct.pack('!I4s', len(payload) + 8, kind) + payload


JPEG = b'\xff\xd8\xff\xe0\0\x06test\xff\xd9'
MOVIE = box(b'ftyp', b'isom\0\0\0\0isom') + box(b'mdat', b'movie-data' * 3) + box(b'moov')


class MotionPhotoTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.root = Path(self.folder.name)
        self.image = self.root / 'image.jpg'
        self.video = self.root / 'image.mov'
        self.image.write_bytes(JPEG)
        self.video.write_bytes(MOVIE)

    async def asyncTearDown(self):
        self.folder.cleanup()

    async def test_android_container_roundtrip_and_oppo_identification(self):
        target = self.root / 'result.MP.jpg'
        await motion.compose(self.image, self.video, target, timestamp=1234567)
        info = motion.motion_photo(target)
        self.assertEqual(info.timestamp_us, 1234567)
        self.assertEqual(info.video_length, len(MOVIE))
        data = target.read_bytes()
        self.assertEqual(data[info.video_offset:], MOVIE)
        self.assertIn(b'OLivePhotoVersion="2"', data)
        self.assertIn(b'MPF\0', data)
        mpf = data.index(b'MPF\0')
        self.assertEqual(struct.unpack_from('!I', data, mpf + 58)[0], info.image_length)
        self.assertEqual(self.image.read_bytes(), JPEG)
        self.assertEqual(self.video.read_bytes(), MOVIE)

    async def test_huawei_cover_is_play_interval_and_frame_index(self):
        target = self.root / 'huawei.jpg'
        await motion.compose(self.image, self.video, target, format='huawei', timestamp=1234567, cover_frame=37, frame_count=90)
        data = target.read_bytes()
        self.assertEqual(data[-60:-40], b'v3_f37'.ljust(20, b' '))
        self.assertEqual(data[-40:-20], b'634:1234'.ljust(20, b' '))
        info = motion.motion_photo(target)
        self.assertEqual(info.cover_frame, 37)
        self.assertEqual(info.format, 'huawei')
        self.assertEqual(data[info.video_offset:info.video_offset + info.video_length], MOVIE)

    async def test_child_elements_and_alternate_xml_prefixes_are_accepted(self):
        target = self.root / 'child.jpg'
        await motion.compose(self.image, self.video, target)
        data = target.read_bytes()
        # RDF attributes and child elements are equivalent representations.
        text = data.decode('latin1')
        for key, value in [('Semantic', 'MotionPhoto'), ('Mime', 'video/mp4'), ('Length', str(len(MOVIE)))]:
            text = text.replace(f'Item:{key}="{value}"', '')
        end = text.index('/>', text.index('<Container:Item', text.index('Item:Semantic="Primary"')))
        # Replace the second self-closing Item with its child-property form.
        text = text[:end] + '><Item:Semantic>MotionPhoto</Item:Semantic><Item:Mime>video/mp4</Item:Mime><Item:Length>' + str(len(MOVIE)) + '</Item:Length></Container:Item>' + text[end+2:]
        raw = text.encode('latin1')
        app = raw.index(b'\xff\xe1')
        # Length changed while replacing XML, repair the APP1 segment header.
        xml_end = raw.index(b'</x:xmpmeta>') + len(b'</x:xmpmeta>')
        raw = raw[:app+2] + struct.pack('!H', xml_end - app - 2) + raw[app+4:]
        target.write_bytes(raw)
        self.assertIsNotNone(motion.motion_photo(target))

    async def test_stale_and_disabled_markers_do_not_create_live_photo(self):
        target = self.root / 'stale.jpg'
        await motion.compose(self.image, self.video, target)
        data = target.read_bytes()
        target.write_bytes(data.replace(b'Camera:MotionPhoto="1"', b'Camera:MotionPhoto="0"'))
        self.assertIsNone(motion.motion_photo(target))
        target.write_bytes(data[:-10])
        self.assertIsNone(motion.motion_photo(target))
        target.write_bytes(data.replace(b'ftyp', b'fake'))
        self.assertIsNone(motion.motion_photo(target))

    async def test_unrelated_same_name_movies_are_all_preserved_in_original_order(self):
        other = self.root / 'image.mp4'
        other.write_bytes(MOVIE)
        selected = [self.video, self.image, other]
        helper = AsyncMock(return_value={'is_live_photo': False})
        with patch.object(motion, 'native', helper):
            result = await motion.prepare_send(selected, self.root / 'work')
        self.assertEqual(result, selected)

    async def test_same_name_pair_without_matching_metadata_stays_two_files(self):
        selected = [self.video, self.image]
        with patch.object(motion, 'native', AsyncMock(return_value={'is_live_photo': False})):
            result = await motion.prepare_send(selected, self.root / 'work')
        self.assertEqual(result, selected)

    async def test_only_a_matching_apple_pair_is_collapsed(self):
        async def helper(command, image, video, output=None, timestamp=-1):
            if command == 'inspect':
                return {'is_live_photo': True}
            output.mkdir()
            still, movie = output / 'still.jpg', output / 'motion.mp4'
            still.write_bytes(JPEG)
            movie.write_bytes(MOVIE)
            return {'image': str(still), 'video': str(movie), 'timestamp_us': 1000000, 'frame_count': 90, 'cover_frame': 30}
        with patch.object(motion, 'native', helper):
            files = await motion.prepare_send([self.video, self.image], self.root / 'work')
        self.assertEqual(len(files), 1)
        self.assertEqual(motion.motion_photo(files[0]).timestamp_us, 1000000)
        self.assertEqual(self.image.read_bytes(), JPEG)
        self.assertEqual(self.video.read_bytes(), MOVIE)

    async def test_invalid_bundle_never_becomes_arbitrary_directory_transfer(self):
        package = self.root / 'bad.pvt'
        package.mkdir()
        (package / 'image.jpg').write_bytes(JPEG)
        (package / 'image.mov').symlink_to(self.video)
        with self.assertRaises(motion.MotionPhotoError):
            await motion.prepare_send([package], self.root / 'work')

    async def test_receive_conversion_failure_preserves_original_success(self):
        target = self.root / 'received.jpg'
        await motion.compose(self.image, self.video, target)
        before = target.read_bytes()
        record = {'path': str(target), 'bytes': len(before), 'sha256': hashlib.sha256(before).hexdigest()}
        events = []
        with patch.object(motion, 'native', AsyncMock(side_effect=motion.MotionPhotoError('test'))):
            result = await motion.materialize_received([record], events.append)
        self.assertEqual(result, [record])
        self.assertEqual(target.read_bytes(), before)
        self.assertEqual(events, ['live_photo_conversion_failed'])
        self.assertEqual(list(self.root.glob('.anDrop-LivePhoto-*')), [])

    async def test_oppo_archive_is_replaced_by_validated_package(self):
        target = self.root / '64c15c15-e153-4e7c-bf16-e585a18e55af@olive.zip'
        with zipfile.ZipFile(target, 'w', zipfile.ZIP_DEFLATED) as archive:
            archive.writestr('camera.jpg', JPEG)
            archive.writestr('camera.mp4', MOVIE)
        before = target.read_bytes()
        record = {'path': str(target), 'bytes': len(before)}
        events = []
        async def helper(command, image, video, output=None, timestamp=-1):
            self.assertEqual(command, 'apple')
            self.assertEqual(image.read_bytes(), JPEG)
            self.assertEqual(video.read_bytes(), MOVIE)
            self.assertEqual(timestamp, -1)
            output.mkdir()
            (output / 'still.jpg').write_bytes(JPEG)
            (output / 'motion.mov').write_bytes(MOVIE)
            return {'is_live_photo': True}
        with patch.object(motion, 'native', helper), patch.object(motion, '_quarantine', return_value=b'0083;fixture;anDrop;'), patch.object(motion, '_set_quarantine') as setter:
            result = await motion.materialize_received([record], events.append)
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0]['kind'], 'live_photo')
        self.assertEqual(events, ['live_photo_converted'])
        self.assertEqual(setter.call_count, 4)
        self.assertFalse(target.exists())
        self.assertNotIn(record, result)
        self.assertEqual(list(self.root.glob('.anDrop-LivePhoto-*')), [])

    async def test_oppo_cleanup_failure_or_replacement_keeps_both_files(self):
        for replace in [False, True]:
            with self.subTest(replace=replace):
                target = self.root / '64c15c15-e153-4e7c-bf16-e585a18e55af@olive.zip'
                with zipfile.ZipFile(target, 'w') as archive:
                    archive.writestr('camera.jpg', JPEG)
                    archive.writestr('camera.mp4', MOVIE)
                record = {'path': str(target)}
                original = target.read_bytes()
                events = []
                async def helper(command, image, video, output=None, timestamp=-1):
                    output.mkdir()
                    (output / 'still.jpg').write_bytes(JPEG)
                    (output / 'motion.mov').write_bytes(MOVIE)
                    if replace:
                        target.write_bytes(b'replacement')
                    return {}
                with patch.object(motion, 'native', helper):
                    if replace:
                        result = await motion.materialize_received([record], events.append)
                    else:
                        with patch.object(Path, 'unlink', side_effect=PermissionError('fixture')):
                            result = await motion.materialize_received([record], events.append)
                self.assertEqual(result[0], record)
                self.assertEqual(result[1]['kind'], 'live_photo')
                self.assertEqual(target.read_bytes(), b'replacement' if replace else original)
                self.assertEqual(events, ['live_photo_converted', 'live_photo_cleanup_failed'])

    async def test_ordinary_zip_with_image_and_video_is_not_auto_imported(self):
        target = self.root / 'ordinary.zip'
        with zipfile.ZipFile(target, 'w') as archive:
            archive.writestr('camera.jpg', JPEG)
            archive.writestr('camera.mp4', MOVIE)
        record = {'path': str(target)}
        events = []
        with patch.object(motion, 'native', AsyncMock()) as helper:
            result = await motion.materialize_received([record], events.append)
        self.assertEqual(result, [record])
        helper.assert_not_awaited()
        self.assertEqual(events, [])

    async def test_broken_oppo_archive_stays_saved_and_does_not_trigger_import(self):
        target = self.root / '64c15c15-e153-4e7c-bf16-e585a18e55af@olive.zip'
        target.write_bytes(b'not an archive')
        record = {'path': str(target)}
        events = []
        with patch.object(motion, 'native', AsyncMock()) as helper:
            result = await motion.materialize_received([record], events.append)
        self.assertEqual(result, [record])
        self.assertEqual(target.read_bytes(), b'not an archive')
        helper.assert_not_awaited()
        self.assertEqual(events, ['live_photo_conversion_failed'])
        self.assertEqual(list(self.root.glob('.anDrop-LivePhoto-*')), [])

    def test_single_converted_photo_is_presented_as_live_photo_with_all_resources(self):
        from engine import Engine
        engine = Engine()
        engine.update = Mock()
        files = [{'path': str(self.root / 'converted.pvt'), 'kind': 'live_photo'}]
        with patch('engine.LANG', 'en'):
            engine.complete_received_files({'id': 'fixture'}, files, 1, 100)
        self.assertEqual(engine.update.call_args.kwargs['name'], 'Live Photo')
        self.assertEqual(engine.update.call_args.kwargs['files'], files)
        engine.complete_received_files({'id': 'fixture'}, [{'path': str(self.root / 'ordinary.zip')}], 1, 100)
        self.assertNotIn('name', engine.update.call_args.kwargs)

    async def test_receive_bundle_is_additive_and_never_overwrites(self):
        target = self.root / 'received.jpg'
        await motion.compose(self.image, self.video, target)
        existing = self.root / 'received.pvt'
        existing.mkdir()
        (existing / 'keep').write_bytes(b'keep')
        record = {'path': str(target), 'bytes': target.stat().st_size}
        async def helper(command, image, video, output=None, timestamp=-1):
            output.mkdir()
            (output / 'still.jpg').write_bytes(JPEG)
            (output / 'motion.mov').write_bytes(MOVIE)
            return {}
        with patch.object(motion, 'native', helper):
            result = await motion.materialize_received([record])
        self.assertEqual(result[1]['kind'], 'live_photo')
        self.assertNotIn('kind', result[0])
        package = Path(result[1]['path'])
        self.assertEqual(package.name, 'received (1).pvt')
        self.assertEqual(plistlib.loads((package / 'metadata.plist').read_bytes()), {'PFVideoComplementMetadataVersionKey': '1'})
        self.assertEqual((existing / 'keep').read_bytes(), b'keep')
        self.assertTrue(target.exists())

    async def test_quarantine_follows_every_derived_resource(self):
        target = self.root / 'received.jpg'
        await motion.compose(self.image, self.video, target)
        async def helper(command, image, video, output=None, timestamp=-1):
            output.mkdir()
            (output / 'still.jpg').write_bytes(JPEG)
            (output / 'motion.mov').write_bytes(MOVIE)
            return {}
        with patch.object(motion, 'native', helper), patch.object(motion, '_quarantine', return_value=b'0083;fixture;anDrop;'), patch.object(motion, '_set_quarantine') as setter:
            await motion.materialize_received([{'path': str(target)}])
        self.assertEqual(setter.call_count, 4)


if __name__ == '__main__':
    unittest.main()
