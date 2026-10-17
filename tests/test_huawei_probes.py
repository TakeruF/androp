"""Offline checks for experimental protocol bounds and redaction."""
import importlib.util
import io
import json
import os
from pathlib import Path
import threading
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch


def load(name):
    path = Path(__file__).resolve().parents[1] / "scripts" / f"{name}.py"
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


auth = load("huawei-auth-probe")
lan = load("huawei-lan-probe")
transfer = load("huawei-transfer-probe")
receiver_discovery = load("huawei-receiver-discovery-probe")


class HuaweiProbeTests(unittest.TestCase):
    def test_incoming_file_uses_the_existing_total_receive_budget(self):
        import struct
        b = transfer.batch_files
        for size in (10990916, b.MAX_TOTAL):
            name = '受信テスト.pdf'.encode()
            batch = b.IncomingBatch(1, size)
            wire = struct.pack('!HHQH', 1, 1, size, len(name)) + name
            parsed = b.parse_header(wire, batch)
            self.assertEqual(parsed[1].size, size)
            self.assertEqual(parsed[1].name, name)
        with self.assertRaises(ValueError):
            b.IncomingFile(b'oversize.pdf', b.MAX_TOTAL + 1)
        with self.assertRaises(ValueError):
            b.IncomingBatch(2, b.MAX_TOTAL + 1)
    def test_file_offer_uses_file_category_and_actual_file_count(self):
        # The category is batch-wide: even an image-first mixed batch must
        # not cause the receiver to open its documents in Gallery.
        for filename, count in [('document.pdf', 1), ('日本語.txt', 2),
                                ('photo.jpg', 3), ('archive.zip', 16)]:
            with self.subTest(filename=filename, count=count):
                names = [filename] + [f'additional-{i}.pdf' for i in range(count - 1)]
                packet = transfer.offer(filename, 1234, count, 'anDrop', filenames=names)
                fields = dict(transfer.tlvs(auth.unwrap_tlv(packet, 7)))
                self.assertEqual(fields[1], b'3')
                self.assertEqual(fields[3], str(count).encode())
                self.assertEqual(fields[5], b'0')
                self.assertEqual(fields[6], str(count).encode())
                self.assertEqual(fields[4], b'1234')
                self.assertEqual(sum(json.loads(fields[7]).values()), count)

    def test_photo_video_and_mixed_offer_routes(self):
        cases = [(['写真.JPG'], 'photo', b'1'),
                 (['one.heic', 'two.PNG', 'three.jpeg'], 'photo', b'1'),
                 (['動画.MOV'], 'video', b'3'),
                 (['one.mp4', 'two.M4V', 'three.webm'], 'video', b'3'),
                 (['photo.jpg', 'movie.mov'], 'mixed', b'3'),
                 (['movie.mov', 'photo.jpg'], 'mixed', b'3'),
                 (['photo.jpg', 'document.pdf'], 'mixed', b'3'),
                 (['document.docx', 'photo.jpg'], 'mixed', b'3'),
                 (['photo.jpg.pdf'], 'file', b'3'),
                 (['photo.jpg.mp4'], 'video', b'3'),
                 (['unknown.raw', 'README'], 'file', b'3')]
        self.assertFalse(transfer.PHOTO_EXTENSIONS & transfer.VIDEO_EXTENSIONS)
        for names, category, send_type in cases:
            with self.subTest(names=names):
                self.assertEqual(transfer.offer_category(names), category)
                fields = dict(transfer.tlvs(auth.unwrap_tlv(transfer.offer(
                    names[0], 1234, len(names), filenames=names), 7)))
                self.assertEqual(fields[1], send_type)
                self.assertEqual(fields[3], str(len(names)).encode())
                self.assertEqual(fields[6], str(len(names)).encode())
                self.assertEqual(json.loads(fields[7]),
                                 json.loads(transfer.extension_summary(names)))

    def test_offer_declares_pdf_word_and_mixed_extensions(self):
        cases = [(['document.PDF'], {'.pdf': 1}),
                 (['文書.doc'], {'.doc': 1}),
                 (['文書.docx'], {'.docx': 1}),
                 (['photo.jpg', '資料.pdf', 'second.PDF', 'word.DOCX', 'sheet.xlsx'],
                  {'.jpg': 1, '.pdf': 2, '.docx': 1, '.xlsx': 1}),
                 (['README', '.hidden', 'data.unknown'], {'': 2, '.unknown': 1})]
        for names, expected in cases:
            with self.subTest(names=names):
                packet = transfer.offer(names[0], 1234, len(names), filenames=names)
                fields = dict(transfer.tlvs(auth.unwrap_tlv(packet, 7)))
                self.assertEqual(json.loads(fields[7]), expected)
                self.assertEqual(fields[1], b'3')

    def test_offer_rejects_incomplete_batch_metadata(self):
        for names, count in [(None, 2), ([], 1), (['first.pdf', 'second.docx'], 1),
                             (['different.pdf'], 1), (['first.pdf'] * 17, 17)]:
            with self.subTest(names=names, count=count), self.assertRaises(ValueError):
                transfer.offer('first.pdf', 1234, count, filenames=names)

    def test_sender_preview_delivers_names_and_requires_authenticated_ack(self):
        from cryptography.hazmat.primitives.ciphers.aead import AESGCM
        r = load('huawei-receive-channels')
        device, session, byte_key = b'0123456789ABCDEF', b's' * 32, b'b' * 32
        names = ['資料.pdf', 'word.docx']
        ack = auth.tlv(1, auth.tlv(8, b'previewOK'))
        for body, inner_key, accepted in [(ack, session, True),
                (auth.tlv(1, auth.tlv(1, b'user_confirm')), session, False),
                (ack, b'x' * 32, False)]:
            with self.subTest(accepted=accepted, body=body):
                response = r.bytes_frame(byte_key, transfer.encrypted_frame(device, inner_key, body, 0)[24:])
                read_fd, write_fd = os.pipe()
                os.write(write_fd, response)
                os.close(write_fd)
                output = io.BytesIO()
                result = {'file_channel_acknowledged': True, 'dfile_settings_verified': True}
                with os.fdopen(read_fd, 'rb', buffering=0) as stream:
                    process = SimpleNamespace(stdin=output, stdout=stream)
                    if accepted:
                        transfer.send_file_preview(process, device, session, byte_key, names, result, lambda: None)
                    else:
                        with self.assertRaises(ValueError):
                            transfer.send_file_preview(process, device, session, byte_key, names, result, lambda: None)
                self.assertTrue(result['file_preview_sent'])
                self.assertEqual(bool(result.get('file_preview_ack_verified')), accepted)
                packet = output.getvalue()[16:]
                inner = AESGCM(byte_key).decrypt(packet[:12], packet[12:], None)
                preview = transfer.decrypt_frame(auth.frame(9, 0, inner), session)
                fields = transfer.tlvs(auth.unwrap_tlv(preview, 8))
                self.assertEqual([tag for tag, _ in fields], [11, 13])
                self.assertEqual(fields[0][1], '資料.pdf|word.docx'.encode())
                self.assertEqual(json.loads(fields[1][1]), {
                    'date_added': [-1, -1], 'date_taken': [-1, -1], 'detail_time': ['', '']})

    def test_preview_cannot_advance_receiver_before_file_transport_is_ready(self):
        for result in ({}, {'file_channel_acknowledged': True},
                       {'dfile_settings_verified': True}):
            with self.subTest(result=result):
                output = io.BytesIO()
                with self.assertRaisesRegex(ValueError, 'file transport must be ready'):
                    transfer.send_file_preview(SimpleNamespace(stdin=output),
                        b'0123456789ABCDEF', b's' * 32, b'b' * 32,
                        ['document.pdf'], result, lambda: None)
                self.assertEqual(output.getvalue(), b'')

    def test_preview_waits_past_avatar_but_requires_authenticated_ack(self):
        r = load('huawei-receive-channels')
        device, session, byte_key = b'0123456789ABCDEF', b's' * 32, b'b' * 32
        avatar = auth.tlv(1, auth.tlv(15, b'private-avatar-data'))
        ack = auth.tlv(1, auth.tlv(8, b'previewOK'))
        busy = auth.tlv(1, auth.tlv(7, b'next_recv'))
        oversized = auth.tlv(1, auth.tlv(15, b'x' * 65537))
        for controls, success in [([avatar, ack], True), ([avatar], False),
                                  ([avatar] * 4 + [ack], False), ([busy, ack], False),
                                  ([oversized, ack], False)]:
            with self.subTest(success=success, count=len(controls)):
                state = {'file_channel_acknowledged': True, 'dfile_settings_verified': True}
                replies = [(0, 0, transfer.encrypted_frame(device, session, body, 0)[24:])
                           for body in controls]
                with patch('importlib.util.module_from_spec') as factory:
                    framing = SimpleNamespace(bytes_frame=r.bytes_frame,
                        read_bytes=Mock(
                            side_effect=replies + [ValueError('EOF')]))
                    factory.return_value = framing
                    with patch('importlib.util.spec_from_file_location') as spec:
                        spec.return_value.loader.exec_module = lambda _: None
                        proc = SimpleNamespace(stdin=io.BytesIO())
                        if success:
                            transfer.send_file_preview(proc, device, session, byte_key,
                                                       ['document.pdf'], state, lambda: None)
                        else:
                            with self.assertRaises(ValueError):
                                transfer.send_file_preview(proc, device, session, byte_key,
                                                           ['document.pdf'], state, lambda: None)
                self.assertEqual(bool(state.get('file_preview_ack_verified')), success)
                self.assertNotIn('private-avatar-data', json.dumps(state))

    def test_batch_sender_receiver_preserves_each_file_and_partial_done(self):
        import struct
        import tempfile
        b, r = transfer.batch_files, load('huawei-receive-channels')
        batch = b.Batch([b.File('日本語.txt'.encode(), '合成データ\n'.encode()),
                         b.File(b'empty.txt', b''), b.File(b'binary.bin', bytes(range(256)) * 31)])
        key = b'k' * 32
        def frame(packet):
            header = struct.unpack_from('!BBHHH', packet)
            return header[:4], packet[8:]
        def control(kind, ids):
            return frame(transfer.dfile_encrypt_control(key, transfer.dfile_packet(kind, 0, 1,
                struct.pack('!' + 'H' * len(ids), *ids))))
        output, sent = io.BytesIO(), {}
        with patch.object(transfer, 'read_dfile_frame', side_effect=[control(2, [2, 1]), control(6, [2]),
                control(2, [1, 3]), control(6, [1, 3])]):
            b.send(transfer, SimpleNamespace(stdin=output), key, batch, sent, lambda: None)
        self.assertEqual(sent['batch_file_ids_done'], [1, 2, 3])
        self.assertTrue(sent['dfile_done_ack_sent'])
        frames = [frame(transfer.dfile_settings())]
        wire = output.getvalue()
        while wire:
            size = struct.unpack_from('!H', wire, 6)[0] + 8
            frames.append(frame(wire[:size])); wire = wire[size:]
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / 'received'
            result = {'preview_ack_sent': True}
            with patch.object(transfer, 'read_dfile_frame', side_effect=frames):
                list(b.receive(transfer, r, SimpleNamespace(stdin=io.BytesIO()), key, batch, destination, result, lambda: None))
            self.assertTrue(result['dfile_done_ack_verified'])
            self.assertEqual({p.name: p.read_bytes() for p in destination.iterdir()},
                             {e.name.decode(): e.content for e in batch.entries})

    def test_batch_rejects_ambiguous_names_symlinks_and_excess_size(self):
        import tempfile
        b = transfer.batch_files
        for names in [[b'a', b'A'], ['é'.encode(), 'e\u0301'.encode()], [b'../x'], [b'x/y'], [b'x\\y'], [b'.'], [b'bad:stream'], [b'trail.']]:
            with self.assertRaises(ValueError):
                b.Batch([b.File(n, b'') for n in names])
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); (root / 'real').write_bytes(b'x'); (root / 'link').symlink_to(root / 'real')
            with self.assertRaises(OSError): b.Batch.from_paths([root / 'link'])
            with self.assertRaises(ValueError): b.Batch.from_paths([root])
            self.assertEqual(b.Batch.from_paths([root / 'real']).size, 1)
        with self.assertRaises(ValueError): b.Batch([])
        with self.assertRaises(ValueError): b.Batch([b.File(str(i).encode(), b'') for i in range(17)])
        with self.assertRaises(ValueError): b.File(b'big', bytes(b.MAX_FILE + 1))

    def test_batch_metadata_fragmentation_and_invalid_done(self):
        import struct
        b = transfer.batch_files
        batch = b.Batch([b.File((str(i) + 'x' * 240).encode(), b'') for i in range(16)])
        parts = list(b.headers(transfer, batch))
        self.assertGreater(len(parts), 1)
        metadata = {}
        for packet in parts:
            self.assertLessEqual(len(packet) + 44, 1472)
            metadata.update(b.parse_header(packet[8:], batch))
        self.assertEqual(set(metadata), set(range(1, 17)))
        for bad in [b'', b'\0', b'\0\0', b'\0\1\0\1', b'\0\x11']:
            with self.assertRaises(ValueError): b.id_list(bad, 16)
        key, output = b'k' * 32, io.BytesIO()
        packet = transfer.dfile_encrypt_control(key, transfer.dfile_packet(6, 0, 1, b'\0\1'))
        with patch.object(transfer, 'read_dfile_frame', return_value=(struct.unpack_from('!BBHHH', packet)[:4], packet[8:])):
            with self.assertRaisesRegex(ValueError, 'premature'):
                b.send(transfer, SimpleNamespace(stdin=output), key, batch, {}, lambda: None)

    def test_batch_receiver_rejects_wrong_content_and_preserves_existing_directory(self):
        import struct
        import tempfile
        b, r, key = transfer.batch_files, load('huawei-receive-channels'), b'k' * 32
        batch = b.Batch([b.File(b'a.txt', b'abc'), b.File(b'b.txt', b'')])
        def frame(packet):
            return struct.unpack_from('!BBHHH', packet)[:4], packet[8:]
        def run(destination, data):
            frames = [frame(transfer.dfile_settings()),
                      frame(transfer.dfile_encrypt_control(key, next(b.headers(transfer, batch)))),
                      frame(transfer.dfile_data_chunk(key, data, 0, 3))]
            with patch.object(transfer, 'read_dfile_frame', side_effect=frames):
                list(b.receive(transfer, r, SimpleNamespace(stdin=io.BytesIO()), key, batch, destination,
                               {'preview_ack_sent': True}, lambda: None))
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / 'received'
            with self.assertRaisesRegex(ValueError, 'digest'): run(destination, b'bad')
            self.assertFalse(destination.exists())
            destination.mkdir(); sentinel = destination / 'keep.txt'; sentinel.write_bytes(b'existing')
            with self.assertRaises(FileExistsError): run(destination, b'abc')
            self.assertEqual(list(destination.iterdir()), [sentinel])
            self.assertEqual(sentinel.read_bytes(), b'existing')

    def test_batch_header_cannot_bind_unknown_duplicate_or_traversal_names(self):
        import struct
        b = transfer.batch_files
        batch = b.Batch([b.File(b'a', b'x'), b.File(b'b', b'')])
        def unit(i, size, name): return struct.pack('!HQH', i, size, len(name)) + name
        for payload in [struct.pack('!H', 3) + unit(1, 1, b'a'),
                        b'\0\2' + unit(0, 1, b'a'), b'\0\2' + unit(3, 1, b'a'),
                        b'\0\2' + unit(1, 1, b'a') + unit(2, 1, b'a'),
                        b'\0\2' + unit(1, 1, b'a') + unit(1, 0, b'b'),
                        b'\0\2' + unit(1, 0, b'a'), b'\0\2' + unit(1, 1, b'../a'),
                        b'\0\2' + unit(1, 1, b'a')[:-1]]:
            with self.assertRaises(ValueError): b.parse_header(payload, batch)

    def test_unreferenced_batch_accepts_content_but_enforces_offer_sizes_and_names(self):
        import struct
        import tempfile
        b, r, key = transfer.batch_files, load('huawei-receive-channels'), b'k' * 32
        source = b.Batch([b.File('任意.txt'.encode(), b'new content'), b.File(b'empty', b'')])
        def frame(packet): return struct.unpack_from('!BBHHH', packet)[:4], packet[8:]
        def run(destination, size):
            frames = [frame(transfer.dfile_settings()),
                      frame(transfer.dfile_encrypt_control(key, next(b.headers(transfer, source)))),
                      frame(transfer.dfile_data_chunk(key, b'new content', 0, 3)),
                      frame(transfer.dfile_encrypt_control(key, transfer.dfile_packet(7, 0, 1, b'')))]
            result = {'preview_ack_sent': True}
            with patch.object(transfer, 'read_dfile_frame', side_effect=frames):
                list(b.receive(transfer, r, SimpleNamespace(stdin=io.BytesIO()), key, b.IncomingBatch(2, size),
                               destination, result, lambda: None))
            return result
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for size in (10, 12):
                with self.assertRaises(ValueError): run(root / str(size), size)
                self.assertFalse((root / str(size)).exists())
            result = run(root / 'good', 11)
            self.assertTrue(result['saved_content_verified'])
            self.assertFalse(result['reference_content_verified'])
            self.assertTrue(result['dfile_done_ack_verified'])
            self.assertEqual((root / 'good' / '任意.txt').read_bytes(), b'new content')
        for name in (b'../escape', b'/absolute', b'a\\b', b'name:stream'):
            payload = struct.pack('!HHQH', 1, 1, 0, len(name)) + name
            with self.assertRaises(ValueError): b.parse_header(payload, b.IncomingBatch(1, 0))

    def test_photo_preview_accepts_bounded_auxiliary_metadata(self):
        r, b = load('huawei-receive-channels'), transfer.batch_files
        fields = auth.tlv(11, b'androp-photo.jpg') + auth.tlv(12, b'x' * 44849)
        # Pura image sharing adds tag 13 after the thumbnail. It is advisory;
        # names/sizes/content are still validated independently in DFile.
        preview = auth.tlv(8, fields + auth.tlv(13, b'x' * 78))
        r.fixture_preview(transfer, preview, b.IncomingBatch(1, 568811))
        for extra in (auth.tlv(13, b'x' * 8193),
                      auth.tlv(14, b'x'), auth.tlv(13, b'x') + auth.tlv(13, b'x')):
            with self.subTest(extra_size=len(extra)), self.assertRaises(ValueError):
                r.fixture_preview(transfer, auth.tlv(8, fields + extra), b.IncomingBatch(1, 568811))

    def test_batch_preview_accepts_missing_or_empty_advisory_media(self):
        r, b = load('huawei-receive-channels'), transfer.batch_files
        # The existing file sender uses tags 11/13 without a thumbnail.
        # Receiving must not depend on the sender's thumbnail/date availability.
        r.fixture_preview(transfer, transfer.file_preview(['restored.jpg']), b.IncomingBatch(1, 123))
        for thumbnail in (b'', b'preview', None):
            for metadata in (b'', b'{}', None):
                fields = auth.tlv(11, '復元写真.jpg'.encode())
                if thumbnail is not None:
                    fields += auth.tlv(12, thumbnail)
                if metadata is not None:
                    fields += auth.tlv(13, metadata)
                with self.subTest(thumbnail=thumbnail, metadata=metadata):
                    r.fixture_preview(transfer, auth.tlv(8, fields), b.IncomingBatch(1, 123))

    def test_batch_preview_optional_media_preserves_structure_and_bounds(self):
        r, b = load('huawei-receive-channels'), transfer.batch_files
        name = auth.tlv(11, b'photo.jpg')
        bad_fields = [b'', auth.tlv(12, b''), auth.tlv(11, b''), auth.tlv(11, b'x' * 1025),
                      auth.tlv(11, b'\xff'), name + name,
                      name + auth.tlv(12, b'') * 2, name + auth.tlv(13, b'') * 2,
                      name + auth.tlv(13, b'{}') + auth.tlv(12, b'x'), name + auth.tlv(14, b''),
                      name + auth.tlv(12, b'x' * (r.PREVIEW_MTU + 1)), name + auth.tlv(13, b'x' * 8193)]
        for fields in bad_fields:
            with self.subTest(size=len(fields)), self.assertRaises(ValueError):
                r.fixture_preview(transfer, auth.tlv(8, fields), b.IncomingBatch(1, 123))

    def test_preview_rejection_records_exact_fixed_reason(self):
        r, b = load('huawei-receive-channels'), transfer.batch_files
        cases = [('field_layout', auth.tlv(11, b'photo.jpg') + auth.tlv(14, b'private')),
                 ('name_size', auth.tlv(11, b'')),
                 ('thumbnail_size', auth.tlv(11, b'photo.jpg') + auth.tlv(12, b'x' * (r.PREVIEW_MTU + 1))),
                 ('metadata_size', auth.tlv(11, b'photo.jpg') + auth.tlv(13, b'x' * 8193))]
        for reason, fields in cases:
            result = {}
            with self.subTest(reason=reason), self.assertRaises(ValueError):
                r.fixture_preview(transfer, auth.tlv(8, fields), b.IncomingBatch(1, 123), diagnostics=result)
            self.assertEqual(result, {'preview_issue': reason})

    def test_multi_file_preview_can_exceed_old_four_kib_mtu(self):
        b, r = transfer.batch_files, load('huawei-receive-channels')
        preview = auth.tlv(8, auth.tlv(11, b'synthetic batch') + auth.tlv(12, b'x' * 10287))
        r.fixture_preview(transfer, preview, b.IncomingBatch(3, 100))
        with self.assertRaises(ValueError):
            r.fixture_preview(transfer, auth.tlv(8, auth.tlv(11, b'name') + auth.tlv(12, b'x' * (r.PREVIEW_MTU + 1))), b.IncomingBatch(1, 0))

    def test_photo_thumbnails_are_bounded_by_transport_not_offer_count(self):
        b, r = transfer.batch_files, load('huawei-receive-channels')
        # Shapes observed in the two-synthetic-JPEG Huawei Share reproduction.
        def preview(thumbnail_size):
            return auth.tlv(8, auth.tlv(11, b'x' * 41) + auth.tlv(12, b'x' * thumbnail_size)
                            + auth.tlv(13, b'x' * 109))
        r.fixture_preview(transfer, preview(89633), b.IncomingBatch(2, 152526))
        for count, size in ((1, 70883), (1, 89633), (2, 120001), (16, 960001)):
            with self.subTest(count=count, size=size):
                r.fixture_preview(transfer, preview(size), b.IncomingBatch(count, 152526))
        for count in (1, 2, 16):
            with self.subTest(count=count), self.assertRaises(ValueError):
                r.fixture_preview(transfer, preview(r.PREVIEW_MTU + 1), b.IncomingBatch(count, 152526))

    def test_byte_channel_cancellation_verifies_both_encryption_layers_and_ack_field(self):
        import struct
        from cryptography.hazmat.primitives.ciphers.aead import AESGCM
        framing = load('huawei-receive-channels')
        identity, session_key, byte_key = b'0123456789ABCDEF', b's' * 32, b'b' * 32
        for sender, field, ack_field, ack in ((True, 2, 3, b'senderCancelACK'), (False, 4, 5, b'receiverCancelACK')):
            for case in ('valid', 'interleaved', 'wrong_field', 'inner_tampered', 'outer_tampered'):
                with self.subTest(sender=sender, case=case):
                    inner = transfer.encrypted_frame(identity, session_key,
                        auth.tlv(1, auth.tlv(1 if case == 'wrong_field' else ack_field, ack)), 0)[24:]
                    if case == 'inner_tampered':
                        inner = inner[:-1] + bytes([inner[-1] ^ 1])
                    wire = framing.bytes_frame(byte_key, inner)
                    if case == 'interleaved':
                        unrelated = transfer.encrypted_frame(identity, session_key, auth.tlv(1, auth.tlv(15, b'opaque')), 0)[24:]
                        wire = framing.bytes_frame(byte_key, unrelated) + wire
                    if case == 'outer_tampered':
                        wire = wire[:-1] + bytes([wire[-1] ^ 1])
                    read_fd, write_fd = os.pipe()
                    os.write(write_fd, wire)
                    os.close(write_fd)
                    result, output = {}, io.BytesIO()
                    with os.fdopen(read_fd, 'rb', buffering=0) as stream:
                        transfer.cancel_bytes(SimpleNamespace(stdin=output, stdout=stream), identity,
                                              session_key, byte_key, result, lambda: None, sender=sender)
                    self.assertEqual(result['byte_cancel_ack_verified'], case in ('valid', 'interleaved'))
                    sent = output.getvalue()
                    self.assertEqual(struct.unpack_from('<IIII', sent)[:3], (auth.MAGIC, 100, 0))
                    envelope = AESGCM(byte_key).decrypt(sent[16:28], sent[28:], None)
                    body = transfer.decrypt_frame(auth.frame(9, 0, envelope), session_key)
                    self.assertEqual(body, auth.tlv(1, auth.tlv(field, b'senderCancel' if sender else b'receiverCancel')))

    def test_large_sender_reconstructs_exact_unicode_fixture(self):
        import struct
        r = load('huawei-receive-channels')
        key, content = b'k' * 32, bytes(range(256)) * 32768
        def reply(kind):
            packet = transfer.dfile_encrypt_control(key, transfer.dfile_packet(kind, 0, 1, b'\0\1'))
            return struct.unpack_from('!BBHHH', packet)[:4], packet[8:]
        stream, result = io.BytesIO(), {'file_data_sent': False}
        with patch.object(transfer, 'read_dfile_frame', side_effect=[reply(2), reply(6)]):
            transfer.send_dfile_fixture(SimpleNamespace(stdin=stream), key, '華為共有検証-独立-123456-8MiB.bin',
                                        content, result, lambda: None)
        wire, offset, chunks, flags = stream.getvalue(), 0, [], []
        while offset < len(wire):
            header = struct.unpack_from('!BBHHH', wire, offset)
            payload = wire[offset + 8:offset + 8 + header[4]]
            self.assertLessEqual(header[4] + 8, 1472)
            if header[0] == 1:
                r.fixture_header(transfer.dfile_decrypt_control(key, header[:4], payload),
                                 r.FixtureSpec('華為共有検証-独立-123456-8MiB.bin'.encode(), len(content),
                                               transfer.hashlib.sha256(content).hexdigest()))
            if header[0] == 4:
                chunks.append(r.decrypt_data_chunk(key, header[:4], payload, len(chunks)))
                flags.append(header[1])
            offset += 8 + header[4]
        self.assertEqual(b''.join(chunks), content)
        self.assertEqual(flags, [0] + [1] * 5898 + [3])
        self.assertEqual(result['data_bytes_queued'], len(content))
        self.assertTrue(result['dfile_done_ack_sent'])

    def test_cancelled_large_sender_stops_before_end_and_done(self):
        import struct
        key, stream = b'k' * 32, io.BytesIO()
        ack = transfer.dfile_encrypt_control(key, transfer.dfile_packet(2, 0, 1, b'\0\1'))
        result = {'file_data_sent': False}
        with patch.object(transfer, 'read_dfile_frame', return_value=(struct.unpack_from('!BBHHH', ack)[:4], ack[8:])):
            with self.assertRaises(transfer.FixtureCancelled):
                transfer.send_dfile_fixture(SimpleNamespace(stdin=stream), key, '華為共有検証-独立-123456-8MiB.bin',
                                            bytes(range(256)) * 32768, result, lambda: None, cancel_after_chunks=64)
        self.assertEqual(result['data_chunks_sent'], 64)
        self.assertEqual(result['data_bytes_queued'], 64 * 1422)
        self.assertFalse(result['file_data_sent'])
        self.assertFalse(result.get('dfile_transfer_done_received', False))
        wire, frames = stream.getvalue(), []
        while wire:
            header = struct.unpack_from('!BBHHH', wire)
            frames.append(header[:2])
            wire = wire[8 + header[4]:]
        self.assertEqual(frames, [(1, 0), (4, 0)] + [(4, 1)] * 63)

    def test_large_source_validation_precedes_network_writes(self):
        stream = io.BytesIO()
        with self.assertRaises(ValueError):
            transfer.send_dfile_fixture(SimpleNamespace(stdin=stream), b'k' * 32,
                                        '華為共有検証-独立-123456-8MiB.bin', bytes(8 * 1024 * 1024), {}, lambda: None)
        self.assertEqual(stream.getvalue(), b'')

    def test_receiver_cancel_uses_field_four_and_requires_authenticated_field_five(self):
        key, identity = b'k' * 32, b'0123456789ABCDEF'
        valid = transfer.encrypted_frame(identity, key, auth.tlv(1, auth.tlv(5, b'receiverCancelACK')), 0)
        wrong_field = transfer.encrypted_frame(identity, key, auth.tlv(1, auth.tlv(1, b'receiverCancelACK')), 0)
        tampered = valid[:-1] + bytes([valid[-1] ^ 1])
        for response, accepted in ((valid, True), (wrong_field, False), (tampered, False)):
            with self.subTest(accepted=accepted, response=response == wrong_field):
                process = SimpleNamespace(stdin=io.BytesIO())
                result = {}
                with patch.object(transfer.auth, 'read_frame', side_effect=[response, ValueError('closed')]):
                    transfer.cancel_receive(process, identity, key, result, lambda: None)
                self.assertEqual(transfer.decrypt_frame(process.stdin.getvalue(), key),
                                 auth.tlv(1, auth.tlv(4, b'receiverCancel')))
                self.assertTrue(result['receiver_cancel_sent'])
                self.assertEqual(result['receiver_cancel_ack_verified'], accepted)

    def test_empty_sender_waits_for_header_ack_and_never_sends_data(self):
        import struct
        key = b'k' * 32
        def reply(kind):
            packet = transfer.dfile_encrypt_control(key, transfer.dfile_packet(kind, 0, 1, b'\0\1'))
            return struct.unpack_from('!BBHHH', packet)[:4], packet[8:]
        stream, result = io.BytesIO(), {'file_data_sent': False}
        with patch.object(transfer, 'read_dfile_frame', side_effect=[reply(6), reply(2), reply(6)]):
            transfer.send_dfile_fixture(SimpleNamespace(stdin=stream), key, 'androp-empty-123456.txt',
                                        b'', result, lambda: None)
        self.assertFalse(result['file_data_sent'])
        self.assertTrue(result['empty_file_no_data_frame'])
        self.assertTrue(result['dfile_transfer_done_received'])
        self.assertTrue(result['dfile_done_ack_sent'])
        wire, kinds = stream.getvalue(), []
        while wire:
            kind, flags, session, transaction, size = struct.unpack_from('!BBHHH', wire)
            kinds.append(kind)
            wire = wire[8 + size:]
        self.assertEqual(kinds, [1, 7])

    def test_receive_fixture_header_rejects_other_names_sizes_and_extra_files(self):
        import struct
        r = load('huawei-receive-channels')
        payload = struct.pack('!HHQH', 1, 1, 77, len(r.FIXTURE_NAME)) + r.FIXTURE_NAME
        r.fixture_header(payload)
        for changed in (struct.pack('!H', 2) + payload[2:], payload + b'\0',
                        struct.pack('!HHQH', 1, 1, 78, len(r.FIXTURE_NAME)) + r.FIXTURE_NAME,
                        struct.pack('!HHQH', 1, 1, 77, 6) + b'../bad'):
            with self.assertRaises(ValueError):
                r.fixture_header(changed)

    def test_receive_fixture_verifies_content_header_and_aead(self):
        import struct
        from cryptography.hazmat.primitives.ciphers.aead import AESGCM
        r = load('huawei-receive-channels')
        key, nonce = b'k' * 32, b'n' * 12
        header = (4, 3, 0, 7)
        def packet(content, transaction=7):
            plain = struct.pack('!HIH', 1, 0, transaction) + content
            return struct.pack('!HI', 1, 0) + AESGCM(key[:16]).encrypt(nonce, plain, b'A' * 64) + nonce
        good = packet(r.FIXTURE)
        self.assertEqual(r.fixture_data(key, header, good), r.FIXTURE)
        for bad in (good[:-13] + bytes([good[-13] ^ 1]) + good[-12:], packet(b'x' * 77),
                    packet(r.FIXTURE, 8), good + b'\0'):
            with self.assertRaises(ValueError):
                r.fixture_data(key, header, bad)

    def test_byte_data_authentication_bounds_and_fragmentation(self):
        import struct
        r = load('huawei-receive-channels')
        key = b'b' * 32
        packet = r.bytes_frame(key, b'synthetic preview envelope', 7)
        def read(data):
            read_fd, write_fd = os.pipe()
            def writer():
                try:
                    for chunk in (data[:3], data[3:19], data[19:]):
                        os.write(write_fd, chunk)
                finally:
                    os.close(write_fd)
            thread = threading.Thread(target=writer)
            thread.start()
            try:
                with os.fdopen(read_fd, 'rb', buffering=0) as stream:
                    return r.read_bytes(SimpleNamespace(stdout=stream), key)
            finally:
                thread.join()
        self.assertEqual(read(packet), (7, 0, b'synthetic preview envelope'))
        # Fragmented pipe reads must preserve both encryption layers above the
        # old MTU, including the outer nonce/tag overhead at the new boundary.
        preview = auth.tlv(8, auth.tlv(11, b'two photos') + auth.tlv(12, b'x' * 89633)
                           + auth.tlv(13, b'x' * 109))
        session_key = b's' * 32
        envelope = transfer.encrypted_frame(b'0123456789ABCDEF', session_key, preview, 0)[24:]
        _, _, decoded = read(r.bytes_frame(key, envelope))
        self.assertEqual(transfer.decrypt_frame(auth.frame(9, 0, decoded), session_key), preview)
        # Reproduce only the field lengths from the user's failed one-photo
        # report; no private image or thumbnail bytes enter this regression.
        single = auth.tlv(8, auth.tlv(11, b'x' * 23) + auth.tlv(12, b'x' * 70883)
                          + auth.tlv(13, b'x' * 97))
        envelope = transfer.encrypted_frame(b'0123456789ABCDEF', session_key, single, 1)[24:]
        _, _, decoded = read(r.bytes_frame(key, envelope, 1))
        body = transfer.decrypt_frame(auth.frame(9, 0, decoded), session_key)
        r.fixture_preview(transfer, body, transfer.batch_files.IncomingBatch(1, 3395444))
        boundary = b'x' * r.PREVIEW_MTU
        self.assertEqual(read(r.bytes_frame(key, boundary))[2], boundary)
        for bad in (packet[:-1], packet[:-1] + bytes([packet[-1] ^ 1]),
                    struct.pack('<IIII', 0xBABEFACE, 0, 0, r.PREVIEW_MTU + r.BYTE_CRYPTO_OVERHEAD + 1),
                    struct.pack('<IIII', auth.MAGIC, 0, 1, 28) + bytes(28)):
            with self.assertRaises(ValueError):
                read(bad)

    def test_byte_channel_eof_is_clean_only_between_frames(self):
        r = load('huawei-receive-channels')
        key = b'b' * 32
        packet = r.bytes_frame(key, b'authenticated preview')
        def read(data):
            read_fd, write_fd = os.pipe()
            os.write(write_fd, data); os.close(write_fd)
            with os.fdopen(read_fd, 'rb', buffering=0) as stream:
                return r.read_bytes(SimpleNamespace(stdout=stream), key)
        with self.assertRaises(r.ByteChannelClosed):
            read(b'')
        for truncated in (packet[:1], packet[:15], packet[:16], packet[:-1]):
            with self.subTest(size=len(truncated)), self.assertRaises(ValueError) as error:
                read(truncated)
            self.assertNotIsInstance(error.exception, r.ByteChannelClosed)

    def test_fixture_preview_rejects_wrong_names_and_duplicate_fields(self):
        r = load('huawei-receive-channels')
        fields = auth.tlv(11, r.FIXTURE_NAME) + auth.tlv(12, b'synthetic thumbnail')
        r.fixture_preview(transfer, auth.tlv(8, fields))
        for bad in (auth.tlv(8, fields + auth.tlv(11, r.FIXTURE_NAME)),
                    auth.tlv(8, auth.tlv(11, b'../other.txt') + auth.tlv(12, r.FIXTURE_NAME)),
                    auth.tlv(8, auth.tlv(11, r.FIXTURE_NAME) + auth.tlv(12, b'')),
                    auth.tlv(7, fields)):
            with self.assertRaises(ValueError):
                r.fixture_preview(transfer, bad)

    def test_receive_dfile_saves_exact_fixture_and_verifies_done_ack(self):
        import struct
        import tempfile
        from cryptography.hazmat.primitives.ciphers.aead import AESGCM
        r = load('huawei-receive-channels')
        key, nonce, transaction = b'k' * 32, b'n' * 12, 9
        header = struct.pack('!HHQH', 1, 1, 77, len(r.FIXTURE_NAME)) + r.FIXTURE_NAME
        data = struct.pack('!HI', 1, 0) + AESGCM(key[:16]).encrypt(
            nonce, struct.pack('!HIH', 1, 0, transaction) + r.FIXTURE, b'A' * 64) + nonce
        wire = (transfer.dfile_settings()
                + transfer.dfile_encrypt_control(key, transfer.dfile_packet(1, 0, transaction, header))
                + transfer.dfile_packet(4, 3, transaction, data)
                + transfer.dfile_encrypt_control(key, transfer.dfile_packet(7, 0, transaction, b'')))
        read_fd, write_fd = os.pipe()
        os.write(write_fd, wire)
        os.close(write_fd)
        result = {'preview_ack_sent': True}
        with tempfile.TemporaryDirectory() as directory, os.fdopen(read_fd, 'rb', buffering=0) as stream:
            path = Path(directory) / 'fixture.txt'
            process = SimpleNamespace(stdout=stream, stdin=io.BytesIO())
            list(r.receive_dfile(transfer, process, key, path, result, lambda: None))
            self.assertEqual(path.read_bytes(), r.FIXTURE)
        self.assertTrue(result['file_received'])
        self.assertTrue(result['saved_content_verified'])
        self.assertTrue(result['dfile_done_ack_verified'])

    def run_reference_receive(self, content, chunks, *, declared=None, digest=None, existing=False):
        import hashlib
        import struct
        import tempfile
        from cryptography.hazmat.primitives.ciphers.aead import AESGCM
        r = load('huawei-receive-channels')
        key, transaction = b'k' * 32, 23
        expected = r.FixtureSpec('検証ファイル.bin'.encode(), len(content) if declared is None else declared,
                                 digest or hashlib.sha256(content).hexdigest())
        def unpack(packet):
            kind, flags, session, trans, size = struct.unpack_from('!BBHHH', packet)
            return (kind, flags, session, trans), packet[8:]
        header = struct.pack('!HHQH', 1, 1, expected.size, len(expected.name)) + expected.name
        frames = [unpack(transfer.dfile_settings()), unpack(transfer.dfile_encrypt_control(
            key, transfer.dfile_packet(1, 0, transaction, header)))]
        for seq, flags, data in chunks:
            nonce = os.urandom(12)
            payload = struct.pack('!HI', 1, seq) + AESGCM(key[:16]).encrypt(
                nonce, struct.pack('!HIH', 1, seq, transaction) + data, b'A' * 64) + nonce
            frames.append(((4, flags, 0, transaction), payload))
        frames.append(unpack(transfer.dfile_encrypt_control(key, transfer.dfile_packet(7, 0, transaction, b''))))
        result = {'preview_ack_sent': True}
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'received.bin'
            if existing:
                path.write_bytes(b'keep existing file')
            process = SimpleNamespace(stdin=io.BytesIO())
            with patch.object(transfer, 'read_dfile_frame', side_effect=frames):
                try:
                    list(r.receive_dfile(transfer, process, key, path, result, lambda: None, expected))
                except (ValueError, FileExistsError):
                    self.assertEqual(path.read_bytes() if path.exists() else None,
                                     b'keep existing file' if existing else None)
                    raise
            self.assertEqual(path.read_bytes(), content)
        return result

    def test_receive_empty_file_without_data_frame(self):
        result = self.run_reference_receive(b'', [])
        self.assertTrue(result['dfile_done_ack_verified'])
        self.assertEqual(result['received_bytes'], 0)
        self.assertNotIn('4', result['dfile_frame_counts'])

    def test_receive_multichunk_unicode_reference(self):
        result = self.run_reference_receive(b'abcdefghij', [(0, 0, b'abcd'), (1, 1, b'efg'), (2, 3, b'hij')])
        self.assertEqual(result['data_chunks_verified'], 3)
        self.assertTrue(result['dfile_done_ack_verified'])

    def test_receive_rejects_sequence_flags_overflow_and_digest(self):
        for chunks, kwargs in [([(1, 3, b'abcdef')], {}), ([(0, 3, b'abc')], {}),
                               ([(0, 0, b'abcdefg')], {}), ([(0, 0, b'abcdef')], {}),
                               ([(0, 3, b'abcdef')], {'digest': '0' * 64}), ([], {})]:
            with self.assertRaises(ValueError):
                self.run_reference_receive(b'abcdef', chunks, **kwargs)

    def test_receive_never_overwrites_existing_destination(self):
        with self.assertRaises(FileExistsError):
            self.run_reference_receive(b'abc', [(0, 3, b'abc')], existing=True)

    def test_reference_spec_rejects_paths_and_excessive_size(self):
        r = load('huawei-receive-channels')
        for name, size in ((b'../bad', 1), (b'a/b', 1), (b'a\\b', 1), (b'', 0),
                           (b'valid.bin', -1), (b'valid.bin', 8 * 1024 * 1024 + 1)):
            with self.assertRaises(ValueError):
                r.FixtureSpec(name, size)

    def test_protocol_v2_identity_preserves_hash_byte_order(self):
        self.assertEqual(auth.protocol_v2_identity(bytes(range(64))), "E0C723677CA4")
        self.assertNotEqual(auth.protocol_v2_identity(bytes(range(64))), "C7E06723A47C")

    def test_receiver_inspects_authenticated_offer_but_never_accepts_file(self):
        from cryptography.hazmat.primitives.asymmetric import rsa, padding
        from cryptography.hazmat.primitives import hashes
        from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat, load_der_public_key
        from cryptography.hazmat.primitives.ciphers.aead import AESGCM
        receiver = load("huawei-receive-probe")
        peer = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        public = peer.public_key().public_bytes(Encoding.DER, PublicFormat.SubjectPublicKeyInfo)
        oaep = padding.OAEP(mgf=padding.MGF1(hashes.SHA256()), algorithm=hashes.SHA256(), label=None)
        stream = io.BytesIO()
        nonce, key = b"n" * 16, b"k" * 32
        state = {}
        def last_packet():
            raw, offset = stream.getvalue(), 0
            while offset < len(raw):
                size = 24 + auth.HEADER.unpack_from(raw, offset)[4]
                packet = raw[offset:offset + size]
                offset += size
            return packet
        def incoming(*args):
            step = state.get("step", 0)
            state["step"] = step + 1
            if step == 0:
                return auth.envelope_frame(b"P" * 16, auth.tlv(2, auth.tlv(1, b"")), 0)
            if step == 1:
                return auth.envelope_frame(b"P" * 16, auth.tlv(6, auth.tlv(1, public)), 0)
            if step == 2:
                _, body = auth.unpack_envelope(last_packet())
                receiver_der = auth.unwrap_tlv(auth.unwrap_tlv(body, 6), 2)
                receiver_key = load_der_public_key(receiver_der)
                ack_length = auth.HEADER.unpack_from(stream.getvalue())[4]
                ack = json.loads(stream.getvalue()[24:24 + ack_length].rstrip(b'\0'))
                expected = auth.protocol_v2_identity(receiver_der)
                self.assertEqual(ack['DEVICE_ID'].upper(), expected)
                self.assertEqual(ack['PEER_NETWORK_ID'].upper(), expected)
                cipher = receiver_key.encrypt(auth.tlv(6, auth.tlv(3, nonce + key)), oaep)
                return auth.frame(9, 0, b"P" * 16 + b"\x81\xe5\x83\x80" + auth.varint(len(cipher)) + cipher)
            _, cipher = auth.unpack_envelope(last_packet())
            encrypted = auth.unwrap_tlv(auth.unwrap_tlv(peer.decrypt(cipher, oaep), 6), 4)
            state["session"] = AESGCM(key).decrypt(nonce, encrypted, None)
            offer = auth.tlv(7, auth.tlv(3, b"1") + auth.tlv(4, b"77")
                             + auth.tlv(7, b"androp-huawei-probe-20261017.txt"))
            return transfer.encrypted_frame(b"P" * 16, state["session"], offer, 0)
        result = {}
        identified = Mock()
        with patch.object(receiver.auth, "read_frame", side_effect=incoming):
            receiver.inspect_offer(SimpleNamespace(stdin=stream), auth.opening("test"), result, lambda: None, identify=identified)
        identified.assert_called_once_with(public)
        self.assertNotIn(public.hex(), json.dumps(result))
        self.assertTrue(result["offer_integrity_verified"])
        self.assertTrue(result["expected_synthetic_offer"])
        self.assertFalse(result["peer_identity_authenticated"])
        rejection = transfer.decrypt_frame(last_packet(), state["session"])
        self.assertEqual(rejection, auth.tlv(1, auth.tlv(1, b"user_reject")))
        self.assertNotIn("user_confirm", stream.getvalue().decode("ascii", errors="ignore"))
        # Merely advertising a copied public key is insufficient: an offer
        # encrypted with a different session key must never expose an identity.
        state.clear(); stream.seek(0); stream.truncate(); identified.reset_mock()
        def forged(*args):
            packet = incoming(*args)
            if state['step'] == 4:
                return transfer.encrypted_frame(b"P" * 16, b'x' * 32, auth.tlv(7, b''), 0)
            return packet
        with patch.object(receiver.auth, 'read_frame', side_effect=forged), self.assertRaisesRegex(ValueError, 'control integrity verification failed'):
            receiver.inspect_offer(SimpleNamespace(stdin=stream), auth.opening('test'), {}, lambda: None, identify=identified)
        identified.assert_not_called()

    def test_receiver_rejects_wrong_session_before_replying(self):
        receiver = load("huawei-receive-probe")
        stream = io.BytesIO()
        opening = auth.frame(8, 0, b'{"CODE":4,"DST_BUS_NAME":"other"}\0')
        with self.assertRaisesRegex(ValueError, "unsupported receive session"):
            receiver.inspect_offer(SimpleNamespace(stdin=stream), opening, {}, lambda: None)
        self.assertEqual(stream.getvalue(), b"")

    def test_receiver_advertisement_has_no_account_hash(self):
        packet = receiver_discovery.advertisement("192.168.99.2", 12345, "test", 1)
        value = json.loads(packet.split(b"\xff", 1)[1])
        self.assertEqual(value["deviceHash"], "")

    def test_receiver_publication_is_distinct_from_discovery_request(self):
        for mode in (1, 10):
            packet = receiver_discovery.advertisement("192.168.99.2", 12345, "A" * 64, 1, mode)
            value = json.loads(packet.split(b"\xff", 1)[1])
            self.assertEqual(value["mode"], mode)
            self.assertEqual(value["type"], 12)
            self.assertEqual("coapUri" in value, mode == 1)
            self.assertEqual(value["serviceData"], "port:12345,")
        for address, port, mode in (("8.8.8.8", 12345, 10), ("192.168.99.2", 0, 10),
                                    ("192.168.99.2", 65536, 10), ("192.168.99.2", 12345, 3)):
            with self.assertRaises(ValueError):
                receiver_discovery.advertisement(address, port, "A" * 64, 1, mode)

    def test_dfile_settings_negotiate_control_and_data_header_encryption_separately(self):
        import struct
        packet = transfer.dfile_settings()
        self.assertEqual(struct.unpack_from("!HH", packet, 8), (1472, 2))
        self.assertEqual(struct.unpack_from("!I", packet, 28)[0], 0x100)
        self.assertEqual(packet[99], 1)
        plain = transfer.dfile_settings(False)
        self.assertEqual(struct.unpack_from("!I", plain, 28)[0], 0)
        self.assertEqual(plain[99], 0)

    def test_dfile_authenticated_control_binds_header_and_rejects_tampering(self):
        import struct
        key = b"k" * 32
        packet = transfer.dfile_encrypt_control(key, transfer.dfile_packet(2, 0, 1, b"\0\1"))
        header = struct.unpack_from("!BBHHH", packet)[:4]
        self.assertEqual(transfer.dfile_decrypt_control(key, header, packet[8:]), b"\0\1")
        with self.assertRaisesRegex(ValueError, "header mismatch"):
            transfer.dfile_decrypt_control(key, (6, 0, 0, 1), packet[8:])
        with self.assertRaisesRegex(ValueError, "integrity"):
            transfer.dfile_decrypt_control(key, header, packet[8:-1] + bytes([packet[-1] ^ 1]))

    def test_dfile_fixture_is_bounded_and_data_stays_encrypted(self):
        from cryptography.hazmat.primitives.ciphers.aead import AESGCM
        key = b"k" * 32
        content = b"anDrop independent Huawei Share LAN test. No personal data.\n"
        with self.assertRaises(ValueError):
            transfer.dfile_file_header("../personal.txt", 60)
        with self.assertRaises(ValueError):
            transfer.dfile_file_data(key, b"personal data")
        for headers in (True, False):
            packet = transfer.dfile_file_data(key, content, headers)
            self.assertNotIn(content, packet)
            plain = AESGCM(key[:16]).decrypt(packet[-12:], packet[14:-12], b"A" * 64)
            self.assertEqual(plain[8:] if headers else plain, content)

    def test_dfile_interleaved_controls_cannot_falsely_complete_transfer(self):
        import struct
        key = b"k" * 32
        def reply(kind, payload):
            packet = transfer.dfile_encrypt_control(key, transfer.dfile_packet(kind, 0, 1, payload))
            return struct.unpack_from("!BBHHH", packet)[:4], packet[8:]
        result = {"file_data_sent": False}
        stream = io.BytesIO()
        frames = [((11, 0, 0, 0), bytes(24)), ((2, 0, 0, 1), b""),
                  reply(6, b"\0\1"), reply(2, b"\0\1"), reply(6, b"\0\1")]
        with patch.object(transfer, "read_dfile_frame", side_effect=frames):
            transfer.send_dfile_fixture(SimpleNamespace(stdin=stream), key, "androp-independent-123456.txt",
                b"anDrop independent Huawei Share LAN test. No personal data.\n", result, lambda: None)
        self.assertTrue(result["file_data_sent"])
        self.assertTrue(result["dfile_transfer_done_received"])
        self.assertEqual(len(result["dfile_transfer_responses"]), 5)
        self.assertFalse(result["dfile_transfer_responses"][0]["integrity_verified"])

    def test_plaintext_next_recv_is_not_authenticated(self):
        summary = transfer.summarize_control(auth.tlv(1, auth.tlv(7, b"next_recv")), False)
        self.assertFalse(summary["integrity_verified"])
        self.assertEqual(summary["commands"][0]["fields"][0]["control"], "next_recv")

    def test_encrypted_control_rejects_tampering_and_wrong_key(self):
        key = b"k" * 32
        body = auth.tlv(1, auth.tlv(1, b"user_confirm"))
        packet = transfer.encrypted_frame(b"0123456789ABCDEF", key, body, 5)
        self.assertEqual(transfer.decrypt_frame(packet, key), body)
        for modified, candidate_key in ((packet[:-1] + bytes([packet[-1] ^ 1]), key),
                                         (packet, b"x" * 32)):
            with self.assertRaisesRegex(ValueError, "integrity"):
                transfer.decrypt_frame(modified, candidate_key)

    def test_control_summary_keeps_only_known_control_values(self):
        body = auth.tlv(1, auth.tlv(1, b"user_confirm")) + auth.tlv(5, auth.tlv(4, b"PRIVATE_NETWORK_VALUE"))
        summary = json.dumps(transfer.summarize_control(body))
        self.assertIn("user_confirm", summary)
        self.assertNotIn("PRIVATE_NETWORK_VALUE", summary)
        with self.assertRaises(ValueError):
            transfer.tlvs(auth.tlv(1, b"abc")[:-1])
        with self.assertRaises(ValueError):
            transfer.tlvs(auth.tlv(1, b"") * 33)

    def test_lan_messages_cannot_advertise_public_or_hotspot_credentials(self):
        for builder in (transfer.logical_connection, transfer.network_request):
            with self.assertRaises(ValueError):
                builder("8.8.8.8")
        tag, body = transfer.tlvs(transfer.network_request("192.168.99.2"))[0]
        self.assertEqual(tag, 4)
        self.assertEqual(dict(transfer.tlvs(body)), {1: b"", 2: b"", 3: b"", 4: b"192.168.99.2"})

    def test_lan_discovery_declares_pc_device_type(self):
        raw = lan.discovery_packet("192.168.99.2", b"12", b"34")
        payload = json.loads(raw.split(b"\xff", 1)[1])
        self.assertEqual(payload["type"], 0x0C)

    def test_file_channel_summary_verifies_integrity_and_redacts_secrets(self):
        from cryptography.hazmat.primitives.ciphers.aead import AESGCM
        key, nonce = b"k" * 32, b"n" * 12
        fields = {"CODE": 1538, "SESSION_KEY": "SECRET_KEY", "MY_IP": "192.168.99.2",
                  "DEVICE_ID": "PRIVATE_ID", "BUS_NAME": "IShareReceiverFileSession"}
        ciphertext = AESGCM(key).encrypt(nonce, json.dumps(fields).encode() + b"\0", None)
        packet = auth.frame(21, 8, auth.HEADER.pack(0xffff0004, 0, 1, 0, len(nonce + ciphertext)) + nonce + ciphertext)
        summary = transfer.summarize_channel(packet, key)
        self.assertTrue(summary["integrity_verified"])
        self.assertEqual(summary["numeric_fields"], {"CODE": 1538})
        for secret in ("SECRET_KEY", "192.168.99.2", "PRIVATE_ID"):
            self.assertNotIn(secret, json.dumps(summary))
        tampered = packet[:-1] + bytes([packet[-1] ^ 1])
        self.assertFalse(transfer.summarize_channel(tampered, key)["integrity_verified"])

    def test_meta_exchange_declares_pc_and_rejects_bad_framing(self):
        key = b"k" * 32
        header = (transfer.META_INFO, 1, 42, 0, 0)
        peer = json.dumps({"DEVICE_NAME": "PRIVATE_NAME", "DEVICE_TYPE_ID": 14,
                           "META_NODE_ID": "PRIVATE_ID", "FLAG": 100}).encode() + b"\0"
        packet = transfer.channel_frame(key, header, peer, 7)
        parsed, plain = transfer.decode_channel(packet, key)
        reply = json.loads(transfer.meta_reply(parsed, plain, "A" * 64))
        self.assertEqual(reply["DEVICE_TYPE_ID"], 12)
        self.assertNotIn("PRIVATE", json.dumps(reply))
        self.assertNotIn("PRIVATE", json.dumps(transfer.summarize_channel(packet, key)))
        malformed = bytearray(packet)
        malformed[44] ^= 1
        with self.assertRaisesRegex(ValueError, "length"):
            transfer.decode_channel(bytes(malformed), key)
        self.assertIsNone(transfer.meta_reply((transfer.META_ACK, 0, 0, 0, 0), b"unrecognized", "A" * 64))

    def test_channel_endpoint_cannot_redirect_outside_test_phone(self):
        for value in ({"P2P_IP": "8.8.8.8", "P2P_PORT": 1234},
                      {"P2P_IP": "192.168.99.3", "P2P_PORT": 1234},
                      {"P2P_IP": "192.168.99.2", "P2P_PORT": True},
                      {"P2P_IP": "192.168.99.2", "P2P_PORT": 65536}):
            with self.assertRaises(ValueError):
                transfer.lan_endpoint(value, "192.168.99.2")
        self.assertEqual(transfer.lan_endpoint({"P2P_IP": "192.168.99.2", "P2P_PORT": 1234}, "192.168.99.2"), ("192.168.99.2", 1234))

    def test_byte_handshake_uses_independent_session_key(self):
        import base64
        key, byte_key = b"k" * 32, b"b" * 32
        packet = transfer.bytes_handshake(key, "SYNTHETIC_ID", byte_key)
        header, plain = transfer.decode_channel(auth.frame(21, 0, packet), key)
        self.assertEqual(header[:2], (auth.MAGIC, 6))
        self.assertEqual(header[3], 0x94)
        value = json.loads(plain.removesuffix(b"\0"))
        self.assertEqual(base64.b64decode(value["SESSION_KEY"]), byte_key)
        self.assertNotEqual(base64.b64decode(value["SESSION_KEY"]), key)

    def test_dfile_rejects_oversized_and_truncated_frames(self):
        import struct
        for packet in (struct.pack("!BBHHH", 8, 0, 0, 0, 14721),
                       struct.pack("!BBHHH", 8, 0, 0, 0, 4) + b"x"):
            read_fd, write_fd = os.pipe()
            os.write(write_fd, packet)
            os.close(write_fd)
            with os.fdopen(read_fd, "rb", buffering=0) as stream:
                with self.assertRaises(ValueError):
                    transfer.read_dfile_frame(SimpleNamespace(stdout=stream))

    def test_discovery_records_redact_identity_and_handle_unicode(self):
        record = {"deviceId": "SECRET_ID", "devicename": "試験端末",
                  "wlanIp": "192.168.99.2", "serviceData": "port:33651,"}
        raw = b"\x60\x00\x12\x34" + json.dumps(record, ensure_ascii=False).encode() * 2
        summary, ports = lan.summarize_capture(raw, b"\x12\x34")
        self.assertEqual(ports, [33651])
        self.assertEqual(len(summary["discovery_records"]), 2)
        self.assertTrue(summary["first_coap_header"]["message_id_matches"])
        for secret in ("SECRET_ID", "192.168.99.2", "試験端末"):
            self.assertNotIn(secret, json.dumps(summary, ensure_ascii=False))
        with self.assertRaises(ValueError):
            lan.summarize_capture(b"x" * 65537, b"\x12\x34")

    def test_final_bit_varint_fixtures_and_truncation(self):
        for value, encoded in [(0, b"\x80"), (101, b"\xe5"), (128, b"\x00\x81"),
                               (294, b"\x26\x82"), (268435455, b"\x7f\x7f\x7f\xff")]:
            self.assertEqual(auth.varint(value), encoded)
            self.assertEqual(auth.read_varint(encoded, 0), (value, len(encoded)))
        for raw in (b"", b"\x01", b"\x00\x00\x00\x00\x80"):
            with self.assertRaises(ValueError):
                auth.read_varint(raw, 0)

    def test_fragmented_tcp_frame_is_reassembled(self):
        packet = auth.frame(8, 9, b'{"CODE":4}\0')
        read_fd, write_fd = os.pipe()
        stream = os.fdopen(read_fd, "rb", buffering=0)
        def writer():
            try:
                for chunk in (packet[:2], packet[2:17], packet[17:25], packet[25:]):
                    os.write(write_fd, chunk)
            finally:
                os.close(write_fd)
        thread = threading.Thread(target=writer)
        thread.start()
        try:
            self.assertEqual(auth.read_frame(SimpleNamespace(stdout=stream)), packet)
        finally:
            stream.close()
            thread.join()

    def test_tcp_oversize_and_truncation_fail_before_parsing(self):
        for packet in (auth.HEADER.pack(auth.MAGIC, 9, 0, 0, auth.LIMIT + 1),
                       auth.HEADER.pack(auth.MAGIC, 9, 0, 0, 4) + b"x"):
            read_fd, write_fd = os.pipe()
            os.write(write_fd, packet)
            os.close(write_fd)
            with os.fdopen(read_fd, "rb", buffering=0) as stream:
                with self.assertRaises(ValueError):
                    auth.read_frame(SimpleNamespace(stdout=stream))

    def test_envelope_rejects_truncated_tlv_and_length_mismatch(self):
        valid = auth.envelope_frame(b"0123456789ABCDEF", auth.tlv(3, b"test"), 2)
        mode, payload = auth.unpack_envelope(valid)
        self.assertEqual(mode, 0)
        self.assertEqual(auth.unwrap_tlv(payload, 3), b"test")
        with self.assertRaises(ValueError):
            auth.unpack_envelope(valid[:-1])
        with self.assertRaises(ValueError):
            auth.unwrap_tlv(payload[:-1], 3)
        with self.assertRaises(ValueError):
            auth.unwrap_tlv(payload, 6)


if __name__ == "__main__":
    unittest.main()
