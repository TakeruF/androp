# SPDX-License-Identifier: GPL-3.0-only
"""Android ZIP streaming: early publication, integrity, bounded I/O and cancellation."""
import asyncio
import hashlib
import io
import os
from pathlib import Path
import struct
import sys
import tempfile
import threading
import tracemalloc
import unittest
import zipfile
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Sources'))
import android_files as files


def zipped(members, *, descriptor=False, method=zipfile.ZIP_DEFLATED):
    class Unseekable(io.BytesIO):
        def seekable(self): return False
        def seek(self, *args): raise io.UnsupportedOperation()
    output = Unseekable() if descriptor else io.BytesIO()
    with zipfile.ZipFile(output, 'w', method, allowZip64=True) as archive:
        for name, data in members:
            with archive.open(name, 'w', force_zip64=True) as target:
                target.write(data)
    return output.getvalue()


class AndroidFileTests(unittest.IsolatedAsyncioTestCase):
    async def test_first_file_visible_before_second_arrives_and_cancel_preserves_it(self):
        first, second = b'first verified contents', os.urandom(128 * 1024)
        raw = zipped([('日本語.txt', first), ('second.bin', second)], descriptor=True)
        split = raw.index(b'PK\x03\x04', 4) + 4  # Descriptor validation peeks at the next signature.
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); dest = root / 'Downloads'; dest.mkdir()
            gate = asyncio.Event(); saved = []
            async def chunks():
                yield raw[:split]
                await gate.wait()
                yield raw[split:]
            task = asyncio.create_task(files.receive_archive(chunks(), root / 'incoming.zip', dest, 2,
                                                            len(first) + len(second), lambda n,t: None, saved))
            try:
                async with asyncio.timeout(3):
                    while not (dest / '日本語.txt').exists(): await asyncio.sleep(.005)
                self.assertEqual((dest / '日本語.txt').read_bytes(), first)
                self.assertFalse((dest / 'second.bin').exists())
                self.assertFalse(task.done())
                task.cancel()
                with self.assertRaises(asyncio.CancelledError): await task
                self.assertEqual([p.name for p in dest.iterdir()], ['日本語.txt'])
                self.assertEqual(len(saved), 1)
            finally:
                task.cancel(); await asyncio.gather(task, return_exceptions=True)

    async def test_crc_failure_preserves_previous_file_and_existing_collision(self):
        raw = bytearray(zipped([('first.txt', b'good'), ('second.txt', b'bad-data')], method=zipfile.ZIP_STORED))
        offset = raw.index(b'bad-data'); raw[offset] ^= 1
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); dest = root / 'Downloads'; dest.mkdir()
            (dest / 'first.txt').write_bytes(b'existing')
            async def chunks(): yield bytes(raw)
            saved = []
            with self.assertRaises(ValueError):
                await files.receive_archive(chunks(), root / 'incoming.zip', dest, 2, 12, lambda n,t: None, saved)
            self.assertEqual((dest / 'first.txt').read_bytes(), b'existing')
            self.assertEqual((dest / 'first (1).txt').read_bytes(), b'good')
            self.assertFalse((dest / 'second.txt').exists())
            self.assertEqual(sorted(p.name for p in dest.iterdir()), ['first (1).txt', 'first.txt'])

    async def test_stored_unknown_size_descriptor_falls_back_without_duplicate_publication(self):
        raw = zipped([('first.txt', b'hello'), ('empty.bin', b'')], descriptor=True, method=zipfile.ZIP_STORED)
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); dest = root / 'Downloads'; dest.mkdir()
            async def chunks():
                for start in range(0, len(raw), 7): yield raw[start:start+7]
            saved = []
            await files.receive_archive(chunks(), root / 'incoming.zip', dest, 2, 5, lambda n,t: None, saved)
            self.assertEqual((dest / 'first.txt').read_bytes(), b'hello')
            self.assertEqual((dest / 'empty.bin').read_bytes(), b'')
            self.assertEqual(len(saved), 2)

    async def test_truncated_central_directory_never_reports_success(self):
        raw = zipped([('first.txt', b'good')])
        raw = raw[:raw.index(b'PK\x01\x02') + 4]
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); dest = root / 'Downloads'; dest.mkdir()
            async def chunks(): yield raw
            saved = []
            with self.assertRaises(zipfile.BadZipFile):
                await files.receive_archive(chunks(), root / 'incoming.zip', dest, 1, 4, lambda n,t: None, saved)
            self.assertEqual((dest / 'first.txt').read_bytes(), b'good')

    async def test_unsafe_paths_and_oversized_output_remain_hidden(self):
        cases = [([('../outside', b'x')], 1), ([('large.bin', b'x' * 100000)], 1)]
        for members, total in cases:
            with self.subTest(members=members[0][0]), tempfile.TemporaryDirectory() as folder:
                root = Path(folder); dest = root / 'Downloads'; dest.mkdir(); raw = zipped(members)
                async def chunks(): yield raw
                with self.assertRaises(ValueError):
                    await files.receive_archive(chunks(), root / 'incoming.zip', dest, 1, total, lambda n,t: None, [])
                self.assertEqual(list(dest.iterdir()), [])
                self.assertFalse((root / 'outside').exists())

    async def test_200_file_roundtrip_keeps_memory_bounded(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); originals = root / 'originals'; originals.mkdir(); dest = root / 'Downloads'; dest.mkdir()
            paths = []; expected = {}
            for i in range(200):
                path = originals / f'{i:03d}-日本語.bin'
                with path.open('wb') as output:
                    for _ in range(48 if i == 0 else 1): output.write(bytes(range(256)) * 4096)
                paths.append(path)
                with path.open('rb') as source: expected[path.name] = hashlib.file_digest(source, 'sha256').hexdigest()
            total = sum(path.stat().st_size for path in paths)
            tracemalloc.start()
            try:
                with patch.object(Path, 'read_bytes', side_effect=AssertionError('Whole file read')):
                    self.assertEqual(await files.create_archive(paths, root / 'outgoing.zip'), total)
                    async def chunks():
                        with (root / 'outgoing.zip').open('rb') as source:
                            while chunk := source.read(files.COPY_CHUNK): yield chunk
                    saved = []
                    await files.receive_archive(chunks(), root / 'incoming.zip', dest, 200, total, lambda n,t: None, saved)
                _, peak = tracemalloc.get_traced_memory()
            finally:
                tracemalloc.stop()
            self.assertLess(peak, 24 * 1024 * 1024)
            self.assertEqual(len(saved), 200)
            for path in dest.iterdir():
                with path.open('rb') as source:
                    self.assertEqual(hashlib.file_digest(source, 'sha256').hexdigest(), expected[path.name])
            print({'android_files': len(saved), 'total_bytes': total, 'python_peak_bytes': peak})

    async def test_sender_opens_one_source_at_a_time_and_loop_remains_responsive(self):
        original_fdopen = files.os.fdopen
        active, events = set(), []
        class Tracked:
            def __init__(self, source):
                self.source = source; active.add(self); events.append(('open', len(active)))
            def __getattr__(self, name): return getattr(self.source, name)
            def __enter__(self): return self
            def __exit__(self, *args): self.close()
            def close(self):
                self.source.close()
                if self in active: active.remove(self); events.append(('close', len(active)))
        def fdopen(*args, **kwargs): return Tracked(original_fdopen(*args, **kwargs))
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); paths = []
            for i in range(85):
                path = root / str(i); path.write_bytes(b'x'); paths.append(path)
            with patch.object(files.os, 'fdopen', side_effect=fdopen):
                await files.create_archive(paths, root / 'files.zip')
            self.assertFalse(active)
            self.assertEqual(events, [('open', 1), ('close', 0)] * 85)
            entered, release = threading.Event(), threading.Event()
            def blocked_fdopen(*args, **kwargs):
                value = fdopen(*args, **kwargs); entered.set(); release.wait(3); return value
            with patch.object(files.os, 'fdopen', side_effect=blocked_fdopen):
                task = asyncio.create_task(files.create_archive(paths, root / 'cancel.zip'))
                async with asyncio.timeout(3):
                    while not entered.is_set(): await asyncio.sleep(.005)
                task.cancel(); await asyncio.sleep(.01)
                self.assertFalse(task.done())  # Cleanup waits for the disk worker.
                release.set()
                with self.assertRaises(asyncio.CancelledError): await task
            self.assertFalse(active)
