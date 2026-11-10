"""Large-selection validation for the local Huawei test build."""
import hashlib
import io
import json
from pathlib import Path
import resource
import socket
import struct
import tempfile
import threading
from types import SimpleNamespace
import tracemalloc
import unittest
from unittest.mock import patch

from test_huawei_probes import transfer, load
from test_huawei_runtime import publish_files


class HuaweiUnlimitedTests(unittest.TestCase):
    def test_200_files_round_trip_above_old_capacity_and_frame_limits(self):
        b, framing, key = transfer.batch_files, load('huawei-receive-channels'), b'k' * 32
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); originals = root / 'originals'; originals.mkdir()
            snapshots = root / 'snapshots'; snapshots.mkdir()
            paths = []
            for index in range(200):
                path = originals / f'{index:03d}-大量転送-日本語ファイル.txt'
                with path.open('wb') as output:
                    if index == 0:
                        for _ in range(48):
                            output.write(bytes(range(256)) * 4096)
                    elif index % 10:
                        output.write(f'content-{index}'.encode() * 100)
                paths.append(path)
            # Keep descriptor use compatible with a standard macOS launch.
            before = resource.getrlimit(resource.RLIMIT_NOFILE)
            try:
                resource.setrlimit(resource.RLIMIT_NOFILE, (min(256, before[0]), before[1]))
                batch = b.Batch.from_paths(paths, snapshot_dir=snapshots)
            finally:
                resource.setrlimit(resource.RLIMIT_NOFILE, before)
            self.assertEqual(batch.count, 200)
            self.assertGreater(batch.size, 16 * 1024 * 1024)
            names = [p.name for p in paths]
            framing.fixture_preview(transfer, transfer.file_preview(names), b.IncomingBatch(200, batch.size))
            # Previews larger than the old 1 MiB MTU fit the negotiated budget.
            preview = transfer.auth.tlv(8, transfer.auth.tlv(11, b'200 photos') + transfer.auth.tlv(12, b'x' * (2 * 1024 * 1024)))
            framing.fixture_preview(transfer, preview, b.IncomingBatch(200, batch.size))
            sender, receiver = socket.socketpair()
            errors, sent, received = [], {}, {'preview_ack_sent': True}
            destination = root / 'received'; destination.mkdir()
            def peer():
                try:
                    with receiver.makefile('wb', buffering=0) as stdin, receiver.makefile('rb', buffering=0) as stdout:
                        process = SimpleNamespace(stdin=stdin, stdout=stdout, buffer_dfile_reads=True)
                        with patch.object(Path, 'read_bytes', side_effect=AssertionError('whole-file read')):
                            list(b.receive(transfer, framing, process, key, b.IncomingBatch(200, batch.size), root / 'received-stage', received, lambda: None, lambda staging, records: publish_files(staging, destination)))
                except BaseException as error:
                    errors.append(error)
                finally:
                    receiver.close()
            worker = threading.Thread(target=peer, daemon=True)
            tracemalloc.start()
            try:
                worker.start()
                with sender.makefile('wb', buffering=0) as stdin, sender.makefile('rb', buffering=0) as stdout:
                    process = SimpleNamespace(stdin=stdin, stdout=stdout)
                    stdin.write(transfer.dfile_settings())
                    header, _ = transfer.read_dfile_frame(process, 5)
                    self.assertEqual(header[0], 8)
                    b.send(transfer, process, key, batch, sent, lambda: None)
                worker.join(30)
                _, peak = tracemalloc.get_traced_memory()
            finally:
                sender.close(); receiver.close(); tracemalloc.stop()
            self.assertFalse(worker.is_alive())
            self.assertEqual(errors, [])
            self.assertTrue(sent['dfile_done_ack_sent'])
            self.assertTrue(received['dfile_done_ack_verified'])
            self.assertGreater(received['dfile_frame_counts']['4'], 32768)
            self.assertLess(peak, 16 * 1024 * 1024)
            print(json.dumps({'files': batch.count, 'total_bytes': batch.size, 'data_frames': received['dfile_frame_counts']['4'], 'python_transfer_peak_bytes': peak}))
            self.assertEqual(len(list(destination.iterdir())), 200)
            self.assertFalse(list(root.glob('.androp-huawei-*')))
            for entry in batch.entries:
                with (destination / entry.name.decode()).open('rb') as source:
                    self.assertEqual(hashlib.file_digest(source, 'sha256').hexdigest(), entry.sha256)

    def test_old_gib_size_limits_removed_without_allocating_file_contents(self):
        b = transfer.batch_files
        entries = [SimpleNamespace(name=f'{i}.bin'.encode(), size=5 * 1024 ** 3) for i in range(4)]
        batch = b.Batch(entries)
        self.assertEqual(batch.size, 20 * 1024 ** 3)
        b.IncomingFile(b'large.bin', entries[0].size)
        b.IncomingBatch(200, batch.size)
        for count in (0, b.MAX_FILES + 1):
            with self.assertRaises(ValueError): b.IncomingBatch(count, 0)
        for size in (-1, b.MAX_RECEIVE_TOTAL + 1):
            with self.assertRaises(ValueError): b.IncomingBatch(1, size)
        for file_id in (200, b.MAX_FILES):
            packet = transfer.dfile_data_chunk(b'k' * 32, b'x', 0, 3, file_id=file_id)
            header = struct.unpack_from('!BBHHH', packet)[:4]
            self.assertEqual(load('huawei-receive-channels').decrypt_data_chunk(b'k' * 32, header, packet[8:], 0, file_id=file_id), b'x')

    def test_failed_receive_cleans_staging_and_rejects_insufficient_disk(self):
        b, framing = transfer.batch_files, load('huawei-receive-channels')
        with tempfile.TemporaryDirectory() as folder:
            destination = Path(folder) / 'received'
            with patch.object(b.shutil, 'disk_usage', return_value=SimpleNamespace(free=0)), self.assertRaises(OSError):
                list(b.receive(transfer, framing, SimpleNamespace(stdin=io.BytesIO()), b'k' * 32, b.IncomingBatch(200, 100), destination, {}, lambda: None))
            self.assertEqual(list(Path(folder).iterdir()), [])
            with patch.object(transfer, 'read_dfile_frame', side_effect=ValueError('interrupted')), self.assertRaisesRegex(ValueError, 'interrupted'):
                list(b.receive(transfer, framing, SimpleNamespace(stdin=io.BytesIO()), b'k' * 32, b.IncomingBatch(200, 100), destination, {}, lambda: None))
            self.assertEqual(list(Path(folder).iterdir()), [])

    def test_snapshot_opens_one_source_at_a_time(self):
        b = transfer.batch_files
        original_fdopen = b.os.fdopen
        active, events = set(), []
        class Tracked:
            def __init__(self, source):
                self.source = source
                active.add(self); events.append(('open', len(active)))
            def __getattr__(self, key): return getattr(self.source, key)
            def __enter__(self): return self
            def __exit__(self, *args): self.close()
            def close(self):
                self.source.close()
                if self in active:
                    active.remove(self); events.append(('close', len(active)))
        def fdopen(*args, **kwargs): return Tracked(original_fdopen(*args, **kwargs))
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); snapshot = root / 'snapshot'; snapshot.mkdir()
            paths = []
            for i in range(85):
                path = root / str(i); path.write_bytes(b'x'); paths.append(path)
            with patch.object(b.os, 'fdopen', side_effect=fdopen):
                self.assertEqual(b.Batch.from_paths(paths, snapshot_dir=snapshot).count, 85)
            self.assertFalse(active)
            self.assertEqual(events, [('open', 1), ('close', 0)] * 85)
            with patch.object(b.os, 'fdopen', side_effect=fdopen), patch.object(b.hashlib, 'sha256', side_effect=ValueError('interrupted')):
                with self.assertRaisesRegex(ValueError, 'interrupted'):
                    b.Batch.from_paths(paths)
            self.assertFalse(active)

    def test_completed_file_is_visible_before_next_file_and_survives_cancel(self):
        b, framing, key = transfer.batch_files, load('huawei-receive-channels'), b'k' * 32
        batch = b.Batch([b.File(b'first.txt', b'abc'), b.File(b'second.txt', b'xyz')])
        def frame(packet): return struct.unpack_from('!BBHHH', packet)[:4], packet[8:]
        frames = [frame(transfer.dfile_settings()),
                  frame(transfer.dfile_encrypt_control(key, next(b.headers(transfer, batch)))),
                  frame(transfer.dfile_data_chunk(key, b'abc', 0, 3, file_id=1)),
                  frame(transfer.dfile_data_chunk(key, b'x', 0, 0, file_id=2))]
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); destination = root / 'Downloads'; destination.mkdir()
            result = {'preview_ack_sent': True}
            with patch.object(transfer, 'read_dfile_frame', side_effect=frames):
                reader = b.receive(transfer, framing, SimpleNamespace(stdin=io.BytesIO()), key, batch,
                                   root / 'stage', result, lambda: None,
                                   lambda staging, records: publish_files(staging, destination))
                next(reader); next(reader)
                self.assertEqual(list(destination.iterdir()), [])
                next(reader)
                self.assertEqual((destination / 'first.txt').read_bytes(), b'abc')
                self.assertFalse((destination / 'second.txt').exists())
                self.assertFalse(result.get('file_received', False))
                self.assertEqual(len(result['saved_files']), 1)
                next(reader)  # Partial data for the second file stays private.
                reader.close()  # Cancellation cleans only uncompleted staging.
            self.assertEqual([p.name for p in destination.iterdir()], ['first.txt'])
            self.assertFalse(list(root.glob('.androp-huawei-*')))

    def test_later_corrupt_file_preserves_earlier_published_file_and_collision(self):
        b, framing, key = transfer.batch_files, load('huawei-receive-channels'), b'k' * 32
        batch = b.Batch([b.File(b'first.txt', b'abc'), b.File(b'second.txt', b'xyz')])
        def frame(packet): return struct.unpack_from('!BBHHH', packet)[:4], packet[8:]
        frames = [frame(transfer.dfile_settings()),
                  frame(transfer.dfile_encrypt_control(key, next(b.headers(transfer, batch)))),
                  frame(transfer.dfile_data_chunk(key, b'abc', 0, 3, file_id=1)),
                  frame(transfer.dfile_data_chunk(key, b'bad', 0, 3, file_id=2))]
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); destination = root / 'Downloads'; destination.mkdir()
            (destination / 'first.txt').write_bytes(b'original')
            result = {'preview_ack_sent': True}
            with patch.object(transfer, 'read_dfile_frame', side_effect=frames), self.assertRaisesRegex(ValueError, 'digest'):
                list(b.receive(transfer, framing, SimpleNamespace(stdin=io.BytesIO()), key, batch,
                               root / 'stage', result, lambda: None,
                               lambda staging, records: publish_files(staging, destination)))
            self.assertEqual((destination / 'first.txt').read_bytes(), b'original')
            self.assertEqual((destination / 'first (1).txt').read_bytes(), b'abc')
            self.assertFalse((destination / 'second.txt').exists())
            self.assertEqual(len(result['saved_files']), 1)
            self.assertFalse(list(root.glob('.androp-huawei-*')))

    def test_partial_metadata_does_not_publish_before_full_offer_is_validated(self):
        b, framing, key = transfer.batch_files, load('huawei-receive-channels'), b'k' * 32
        batch = b.IncomingBatch(2, 6)
        def frame(packet): return struct.unpack_from('!BBHHH', packet)[:4], packet[8:]
        def metadata(file_id, name, size):
            payload = struct.pack('!HHQH', 2, file_id, size, len(name)) + name
            return frame(transfer.dfile_encrypt_control(key, transfer.dfile_packet(1, 0, 1, payload)))
        frames = [frame(transfer.dfile_settings()), metadata(1, b'first.txt', 3),
                  frame(transfer.dfile_data_chunk(key, b'abc', 0, 3, file_id=1)),
                  metadata(2, b'second.txt', 4)]  # Accepted total is 6, not 7.
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); destination = root / 'Downloads'; destination.mkdir()
            with patch.object(transfer, 'read_dfile_frame', side_effect=frames):
                reader = b.receive(transfer, framing, SimpleNamespace(stdin=io.BytesIO()), key, batch,
                                   root / 'stage', {'preview_ack_sent': True}, lambda: None,
                                   lambda staging, records: publish_files(staging, destination))
                next(reader); next(reader); next(reader)
                self.assertEqual(list(destination.iterdir()), [])
                with self.assertRaisesRegex(ValueError, 'metadata total'):
                    next(reader)
            self.assertEqual(list(destination.iterdir()), [])
