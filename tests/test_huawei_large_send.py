"""Large Huawei sends: bounded memory, duplex ACKs and 32-bit sequences."""
import hashlib
import io
import os
from pathlib import Path
import socket
import struct
import tempfile
import threading
from types import SimpleNamespace
import tracemalloc
import unittest
from unittest.mock import patch

from test_huawei_probes import transfer, load


class HuaweiLargeSendTests(unittest.TestCase):
    def test_large_snapshot_is_streamed_and_independent_of_original(self):
        batch_files = transfer.batch_files
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); original = root / '大容量.bin'
            with original.open('wb') as output:
                for _ in range(32):
                    output.write(bytes(range(256)) * 4096)
            snapshot = root / 'snapshot'; snapshot.mkdir()
            tracemalloc.start()
            try:
                with patch.object(Path, 'read_bytes', side_effect=AssertionError('whole-file read')):
                    batch = batch_files.Batch.from_paths([original], snapshot_dir=snapshot)
                _, peak = tracemalloc.get_traced_memory()
            finally:
                tracemalloc.stop()
            self.assertLess(peak, 8 * 1024 * 1024)
            self.assertEqual(batch.size, 32 * 1024 * 1024)
            original.write_bytes(b'changed original')
            digest = hashlib.sha256()
            for chunk in batch.entries[0].chunks():
                self.assertLessEqual(len(chunk), 1422)
                digest.update(chunk)
            self.assertEqual(digest.hexdigest(), batch.entries[0].sha256)
            batch.entries[0].path.write_bytes(b'changed snapshot')
            with self.assertRaisesRegex(ValueError, 'source changed'):
                next(batch.entries[0].chunks())

    def test_size_limits_are_checked_before_copying_or_hashing(self):
        b = transfer.batch_files
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            too_big = root / 'oversize.bin'
            with too_big.open('wb') as output:
                output.truncate(b.MAX_SEND_FILE + 1)
            with self.assertRaisesRegex(ValueError, '4 GiB'):
                b.Batch.from_paths([too_big])
            files = []
            for number in range(5):
                path = root / str(number)
                with path.open('wb') as output:
                    output.truncate(b.MAX_SEND_FILE)
                files.append(path)
            with patch.object(b.hashlib, 'sha256', side_effect=AssertionError('hashed oversized batch')):
                with self.assertRaisesRegex(ValueError, '16 GiB'):
                    b.Batch.from_paths(files)
            # The maximum file size is encoded as a 64-bit count, without wrap.
            entry = b.DiskFile(files[0], files[0].stat(), '0' * 64)
            packet = next(b.headers(transfer, b.Batch([entry])))
            self.assertEqual(struct.unpack_from('!Q', packet, 12)[0], 4 * 1024 ** 3)
            stopped = threading.Event(); stopped.set()
            with self.assertRaisesRegex(ValueError, 'cancelled'):
                b.Batch.from_paths([files[0]], stopped=stopped)

    def test_data_sequences_use_all_32_bits(self):
        framing = load('huawei-receive-channels'); key = b'k' * 32
        for sequence in [16383, 16384, 2 ** 31, 2 ** 32 - 1]:
            packet = transfer.dfile_data_chunk(key, b'data', sequence, 1)
            header = struct.unpack_from('!BBHHH', packet)[:4]
            self.assertEqual(framing.decrypt_data_chunk(key, header, packet[8:], sequence), b'data')
        for sequence in [-1, 2 ** 32]:
            with self.assertRaises(ValueError):
                transfer.dfile_data_chunk(key, b'data', sequence, 1)

    def test_64_mib_socket_transfer_drains_acknowledgements_and_preserves_content(self):
        b = transfer.batch_files; framing = load('huawei-receive-channels')
        key = b'k' * 32
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / '大きなファイル.bin'
            with path.open('wb') as output:
                for _ in range(64):
                    output.write(bytes(range(256)) * 4096)
            batch = b.Batch.from_paths([path])
            sender, receiver = socket.socketpair()
            receiver.settimeout(20)
            receiver.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 4096)
            errors, received, progress = [], {}, []
            def exact(count):
                data = bytearray()
                while len(data) < count:
                    chunk = receiver.recv(count - len(data))
                    if not chunk: raise ValueError('unexpected EOF')
                    data.extend(chunk)
                return bytes(data)
            def control(kind, payload):
                packet = transfer.dfile_encrypt_control(key, transfer.dfile_packet(kind, 0, 1, payload))
                # Exercise partial headers without relying on TCP packet boundaries.
                receiver.sendall(packet[:3]); receiver.sendall(packet[3:])
            def peer():
                try:
                    digest = hashlib.sha256(); sequence = 0; total = 0
                    while True:
                        header = struct.unpack('!BBHHH', exact(8)); payload = exact(header[4])
                        if header[0] == 1:
                            control(2, b'\0\1')
                        elif header[0] == 4:
                            chunk = framing.decrypt_data_chunk(key, header[:4], payload, sequence)
                            digest.update(chunk); total += len(chunk); sequence += 1
                            if sequence % 32 == 0:
                                control(5, b'')
                            if header[1] == 3:
                                received.update(bytes=total, sha256=digest.hexdigest(), chunks=sequence)
                                control(6, b'\0\1')
                        elif header[0] == 7:
                            self.assertEqual(transfer.dfile_decrypt_control(key, header[:4], payload), b'')
                            break
                        else:
                            raise AssertionError('unexpected sender frame')
                except BaseException as error:
                    errors.append(error)
            worker = threading.Thread(target=peer, daemon=True); worker.start()
            result = {}; tick = [0.0]
            def clock():
                tick[0] += .004
                return tick[0]
            tracemalloc.start()
            try:
                with sender.makefile('wb', buffering=0) as stdin, sender.makefile('rb', buffering=0) as stdout:
                    with patch.object(b, 'time', SimpleNamespace(monotonic=clock)):
                        b.send(transfer, SimpleNamespace(stdin=stdin, stdout=stdout), key, batch, result,
                               lambda: progress.append(result.get('data_bytes_queued', 0)))
                worker.join(20)
                _, peak = tracemalloc.get_traced_memory()
            finally:
                sender.close(); receiver.close(); tracemalloc.stop()
            self.assertFalse(worker.is_alive())
            self.assertEqual(errors, [])
            self.assertEqual(received['bytes'], batch.size)
            self.assertEqual(received['sha256'], batch.entries[0].sha256)
            self.assertGreater(received['chunks'], 16384)
            self.assertGreater(tick[0], 60)  # Total duration may exceed the idle timeout.
            self.assertLess(peak, 16 * 1024 * 1024)
            self.assertGreater(result['batch_control_counts']['5'], 128)
            self.assertLessEqual(len(result['batch_control_frames']), 128)
            self.assertTrue(any(0 < value < batch.size for value in progress))
            self.assertEqual(result['data_bytes_queued'], batch.size)
            self.assertTrue(result['dfile_done_ack_sent'])


if __name__ == '__main__':
    unittest.main()
