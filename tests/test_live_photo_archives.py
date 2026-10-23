# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 anDrop contributors
"""Vendor ZIP recognition and bounded extraction, using synthetic bytes only."""
import asyncio
import io
import os
from pathlib import Path
import stat
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Sources'))
import live_photo_archives as archives


NAME = '11111111-2222-4333-8444-555555555555@olive.zip'


class ArchiveTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.source = self.root / NAME
        self.output = self.root / 'output'
        self.output.mkdir()

    async def asyncTearDown(self):
        self.temporary.cleanup()

    def write(self, members=None, method=zipfile.ZIP_DEFLATED):
        if members is None:
            members = [('photo.jpg', b'jpeg-content'), ('photo.mp4', b'movie-content')]
        with zipfile.ZipFile(self.source, 'w', compression=method) as archive:
            for name, content in members:
                archive.writestr(name, content)
        return self.source.read_bytes()

    async def reject(self):
        original = self.source.read_bytes()
        with self.assertRaisesRegex(ValueError, '^live_photo_invalid_archive$'):
            await archives.extract_olive_archive(self.source, self.output)
        self.assertEqual(original, self.source.read_bytes())

    def mutate(self, callback):
        data = bytearray(self.source.read_bytes())
        callback(data)
        self.source.write_bytes(data)

    def test_vendor_names_only(self):
        self.assertTrue(archives.is_olive_archive(NAME))
        self.assertTrue(archives.is_olive_archive(NAME.replace('@olive.zip', '@olive (2).zip')))
        self.assertTrue(archives.is_olive_archive(NAME.upper()))
        for name in ('photo.zip', 'photo@olive.zip', NAME + '.zip',
                     NAME.replace('@olive.zip', '@olive (0).zip'),
                     NAME.replace('@olive.zip', '@ios.zip')):
            self.assertFalse(archives.is_olive_archive(name), name)

    async def test_two_components_preserve_source(self):
        for method in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED):
            with self.subTest(method=method):
                original = self.write(method=method)
                image, movie = await archives.extract_olive_archive(self.source, self.output)
                self.assertEqual(image.name, 'still.jpg')
                self.assertEqual(movie.name, 'motion.mp4')
                self.assertEqual(image.read_bytes(), b'jpeg-content')
                self.assertEqual(movie.read_bytes(), b'movie-content')
                self.assertEqual(self.source.read_bytes(), original)
                image.unlink()
                movie.unlink()

    async def test_optional_gainmap_and_casefold_pair(self):
        self.write([('Photo.JPG', b'jpeg'), ('photo.MOV', b'mov'),
                    ('PHOTO_gainmap.jpg', b'hdr')])
        image, movie = await archives.extract_olive_archive(self.source, self.output)
        self.assertEqual(image.name, 'still.jpg')
        self.assertEqual(movie.name, 'motion.mov')
        self.assertEqual((self.output / 'gainmap.jpg').read_bytes(), b'hdr')

    async def test_nonseekable_writer_data_descriptors(self):
        class Stream(io.BytesIO):
            def seekable(self):
                return False
            def seek(self, *args):
                raise OSError('unseekable')
        stream = Stream()
        with zipfile.ZipFile(stream, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
            archive.writestr('p.jpg', b'image')
            archive.writestr('p.mp4', b'video')
        self.source.write_bytes(stream.getvalue())
        await archives.extract_olive_archive(self.source, self.output)

    async def test_reject_paths_unknowns_duplicates_and_pair_mismatch(self):
        pairs = [
            [('a.jpg', b'x'), ('../a.mp4', b'y')],
            [('a.jpg', b'x'), ('a\\x.mp4', b'y')],
            [('a.jpg', b'x'), ('C:a.mp4', b'y')],
            [('a.jpg', b'x'), ('a\n.mp4', b'y')],
            [('a.jpg', b'x'), ('a\u202e.mp4', b'y')],
            [('a.jpg', b'x'), ('a.mp4', b'y'), ('secret.txt', b'z')],
            [('a.jpg', b'x'), ('A.JPG', b'y')],
            [('a.jpg', b'x'), ('b.mp4', b'y')],
            [('a.jpg', b'x'), ('a.mp4', b'y'), ('other_gainmap.jpg', b'z')],
            [('a.jpg', b'x'), ('a.mp4', b'y'), ('a_gainmap.png', b'z')],
            [('x' * 256 + '.jpg', b'x'), ('a.mp4', b'y')],
            [('a.jpg', b'x'), ('a.mp4', b'y'), ('directory/', b'')],
        ]
        for members in pairs:
            with self.subTest(names=[p[0] for p in members]):
                self.write(members)
                await self.reject()
                self.assertEqual(list(self.output.iterdir()), [])

    async def test_reject_symlink_device_entry(self):
        for kind in (stat.S_IFLNK, stat.S_IFCHR, stat.S_IFDIR):
            entry = zipfile.ZipInfo('p.jpg')
            entry.create_system = 3
            entry.external_attr = (kind | 0o644) << 16
            self.write([(entry, b'payload'), ('p.mp4', b'movie')])
            await self.reject()

    async def test_reject_source_symlink_fifo_and_nonvendor_name(self):
        self.write()
        symlink = self.root / NAME.replace('11111111', 'aaaaaaaa')
        symlink.symlink_to(self.source)
        with self.assertRaises(ValueError):
            await archives.extract_olive_archive(symlink, self.output)
        fifo = self.root / NAME.replace('11111111', 'bbbbbbbb')
        os.mkfifo(fifo)
        with self.assertRaises(ValueError):
            await asyncio.wait_for(archives.extract_olive_archive(fifo, self.output), 1)
        ordinary = self.root / 'ordinary.zip'
        ordinary.write_bytes(self.source.read_bytes())
        with self.assertRaises(ValueError):
            await archives.extract_olive_archive(ordinary, self.output)

    async def test_nul_in_raw_name_rejected(self):
        self.write()
        self.mutate(lambda data: data.__setitem__(slice(None), data.replace(b'photo.jpg', b'ph\0to.jpg')))
        await self.reject()

    async def test_encryption_local_and_central_flags_rejected(self):
        for central in (False, True):
            self.write()
            def change(data):
                start = data.index(b'PK\x01\x02') + 8 if central else 6
                struct.pack_into('<H', data, start, 1)
            self.mutate(change)
            await self.reject()

    async def test_bad_crc_is_neutral_error(self):
        self.write(method=zipfile.ZIP_STORED)
        self.mutate(lambda data: data.__setitem__(data.index(b'jpeg-content'), ord('X')))
        await self.reject()

    async def test_aggregate_size_checked_before_zipfile_construction(self):
        self.write()
        self.mutate(lambda data: struct.pack_into('<I', data, data.index(b'PK\x01\x02') + 24,
                                                  archives.MAX_MEDIA))
        with patch.object(archives.zipfile, 'ZipFile', side_effect=AssertionError('must preflight')):
            await self.reject()

    async def test_count_directory_bound_multidisk_trailing_and_prefix_rejected(self):
        edits = [lambda d: struct.pack_into('<H', d, len(d) - 22 + 10, 60000),
                 lambda d: struct.pack_into('<I', d, len(d) - 22 + 12, 65537),
                 lambda d: struct.pack_into('<H', d, len(d) - 22 + 4, 1),
                 lambda d: d.extend(b'ignored-tail'),
                 lambda d: d.__setitem__(slice(None), b'SFX!' + d)]
        for edit in edits:
            self.write()
            self.mutate(edit)
            with patch.object(archives.zipfile, 'ZipFile', side_effect=AssertionError('must preflight')):
                await self.reject()

    async def test_zip64_and_unsupported_compression_rejected(self):
        entry = zipfile.ZipInfo('photo.jpg')
        entry.extra = struct.pack('<HHQ', 1, 8, 4)
        self.write([(entry, b'jpeg'), ('photo.mp4', b'movie')])
        await self.reject()
        self.write(method=zipfile.ZIP_BZIP2)
        await self.reject()

    async def test_destination_collision_does_not_overwrite(self):
        self.write()
        target = self.output / 'still.jpg'
        target.write_bytes(b'keep')
        await self.reject()
        self.assertEqual(target.read_bytes(), b'keep')

    async def test_cancellation_propagates_source_unchanged_and_handles_close(self):
        original = self.write([('p.jpg', b'i' * (archives.CHUNK * 2)), ('p.mp4', b'video')])
        real_sleep = asyncio.sleep
        async def cancel(_):
            raise asyncio.CancelledError
        with patch.object(archives.asyncio, 'sleep', cancel):
            with self.assertRaises(asyncio.CancelledError):
                await archives.extract_olive_archive(self.source, self.output)
        self.assertEqual(self.source.read_bytes(), original)
        # The caller's TemporaryDirectory can remove partial components immediately.
        (self.output / 'still.jpg').unlink()
        await real_sleep(0)


if __name__ == '__main__':
    unittest.main()
