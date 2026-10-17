#!/usr/bin/env python3
"""Bounded receive experiment: explicit fixtures or one file batch on the existing LAN."""
import base64
import hashlib
import json
import os
import secrets
import select
import socket
import struct
import subprocess
import time

FIXTURE_NAME = b'androp-huawei-probe-20261017.txt'
FIXTURE = b'anDrop Huawei Share compatibility probe\n2026-10-17\nSynthetic test data only.\n'
# SoftBus checks the whole encrypted application preview against our advertised
# MTU before sending it. Two photo thumbnails already exceed 64 KiB on Pura.
# Bound both negotiation and allocation; the outer AES-GCM adds 28 bytes.
PREVIEW_MTU = 1024 * 1024
BYTE_CRYPTO_OVERHEAD = 28


class FixtureSpec:
    def __init__(self, name=FIXTURE_NAME, size=len(FIXTURE), sha256=None):
        if (not isinstance(name, bytes) or not 1 <= len(name) <= 255 or name in (b'.', b'..')
                or any(c in name for c in (b'/', b'\\', b'\0'))):
            raise ValueError('fixture name must be a single UTF-8 filename')
        name.decode('utf-8', errors='strict')
        if type(size) is not int or not 0 <= size <= 8 * 1024 * 1024:
            raise ValueError('fixture must be between 0 and 8 MiB')
        sha256 = sha256 if sha256 is not None else hashlib.sha256(FIXTURE).hexdigest()
        if len(sha256) != 64 or any(c not in '0123456789abcdef' for c in sha256):
            raise ValueError('invalid fixture digest')
        self.name, self.size, self.sha256 = name, size, sha256

    @classmethod
    def from_path(cls, path):
        size = path.stat().st_size
        if size > 8 * 1024 * 1024:
            raise ValueError('fixture exceeds 8 MiB')
        return cls(path.name.encode('utf-8'), size, hashlib.sha256(path.read_bytes()).hexdigest())


def fixture_header(payload, expected=None):
    expected = expected or FixtureSpec()
    if len(payload) < 14:
        raise ValueError('short fixture header')
    count, file_id, size, name_len = struct.unpack_from('!HHQH', payload)
    if ((count, file_id, size) != (1, 1, expected.size) or payload[14:] != expected.name
            or name_len != len(expected.name)):
        raise ValueError('DFile header is not the allowed fixture')


def decrypt_data_chunk(key, header, payload, sequence, file_id=1):
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    from cryptography.exceptions import InvalidTag
    if header[0] != 4 or header[1] not in (0, 1, 3) or header[2] != 0 or not 42 <= len(payload) <= 14720:
        raise ValueError('unsupported fixture data framing')
    if payload[:6] != struct.pack('!HI', file_id, sequence):
        raise ValueError('unexpected fixture sequence')
    try:
        plain = AESGCM(key[:16]).decrypt(payload[-12:], payload[6:-12], b'A' * 64)
    except InvalidTag:
        raise ValueError('fixture data integrity failed') from None
    if plain[:8] != struct.pack('!HIH', file_id, sequence, header[3]):
        raise ValueError('fixture authenticated header differs')
    return plain[8:]


def fixture_data(key, header, payload):
    # Retain the original one-packet regression fixture.
    plain = decrypt_data_chunk(key, header, payload, 0)
    if header[1] != 3 or plain != FIXTURE:
        raise ValueError('fixture content differs')
    return plain


def fixture_preview(t, body, expected=None, diagnostics=None):
    expected = expected or FixtureSpec()
    fields = t.tlvs(t.auth.unwrap_tlv(body, 8))
    if hasattr(expected, 'entries') and (expected.count > 1 or not expected.name):
        # The native multi-file preview may use a summary name. Exact names and
        # sizes are bound to the local reference set by every DFile header.
        # Thumbnails (12) and media dates (13) are advisory. The file sender
        # also uses 11/13 without a thumbnail; missing/empty media must not
        # prevent receiving the independently authenticated DFile contents.
        # Keep ordered, unique known fields and the existing allocation bounds.
        # Thumbnail size is independent of file count: a single Pura photo
        # produced 70,883 B. Use the already bounded preview transport budget,
        # rather than the earlier estimate of 60,000 B per file. No thumbnail
        # decoding occurs here; read_bytes bounds the entire encrypted frame.
        # Never use preview fields as a path, size or authority for file data.
        tags = [tag for tag, _ in fields]
        values = dict(fields)
        issue = None
        if tags not in ([11], [11, 12], [11, 13], [11, 12, 13]):
            issue = 'field_layout'
        elif not 1 <= len(values[11]) <= 1024:
            issue = 'name_size'
        elif len(values.get(12, b'')) > PREVIEW_MTU:
            issue = 'thumbnail_size'
        elif len(values.get(13, b'')) > 8192:
            issue = 'metadata_size'
        if issue:
            if diagnostics is not None:
                diagnostics['preview_issue'] = issue
            raise ValueError('unsupported batch preview')
        fields[0][1].decode('utf-8', errors='strict')
        return
    if ([tag for tag, _ in fields] != [11, 12] or fields[0][1] != expected.name
            or not 1 <= len(fields[1][1]) <= 8192):
        raise ValueError('unsupported fixture preview')


def bytes_frame(key, plain, sequence=0):
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    nonce = struct.pack('<I', sequence) + secrets.token_bytes(8)
    encrypted = nonce + AESGCM(key).encrypt(nonce, plain, None)
    return struct.pack('<IIII', 0xBABEFACE, sequence, 0, len(encrypted)) + encrypted

class ByteChannelClosed(ValueError):
    """Orderly EOF between authenticated preview frames, never a partial frame."""


def read_bytes(process, key):
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    from cryptography.exceptions import InvalidTag
    deadline = time.monotonic() + 4
    def exact(size, allow_eof=False):
        data = bytearray()
        while len(data) < size:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([process.stdout], [], [], remaining)[0]:
                raise ValueError('byte data deadline')
            chunk = os.read(process.stdout.fileno(), size - len(data))
            if not chunk:
                if allow_eof and not data:
                    raise ByteChannelClosed('byte data connection closed')
                raise ValueError('byte data connection closed')
            data.extend(chunk)
        return bytes(data)
    magic, seq, flags, size = struct.unpack('<IIII', exact(16, allow_eof=True))
    if magic != 0xBABEFACE or flags != 0 or not BYTE_CRYPTO_OVERHEAD <= size <= PREVIEW_MTU + BYTE_CRYPTO_OVERHEAD:
        raise ValueError('unsupported byte data frame')
    payload = exact(size)
    try:
        plain = AESGCM(key).decrypt(payload[:12], payload[12:], None)
    except InvalidTag:
        raise ValueError('byte data integrity failed') from None
    return seq, flags, plain

def receive_dfile(t, process, key, destination, result, save, expected=None):
    expected = expected or FixtureSpec()
    def send(packet):
        process.stdin.write(packet)
        process.stdin.flush()
    def finish(content, transaction):
        if len(content) != expected.size or hashlib.sha256(content).hexdigest() != expected.sha256:
            raise ValueError('received fixture size or digest differs')
        # Remote filenames are never interpreted as paths. No partial file is published.
        with open(destination, 'xb') as output:
            output.write(content)
            output.flush()
            os.fsync(output.fileno())
        if hashlib.sha256(destination.read_bytes()).hexdigest() != expected.sha256:
            raise ValueError('saved fixture readback differs')
        result.update(file_received=True, received_bytes=len(content), saved_content_verified=True,
                      received_sha256=expected.sha256)
        send(t.dfile_encrypt_control(key, t.dfile_packet(6, 0, transaction, struct.pack('!H', 1))))
        result['dfile_done_sent'] = True
    deadline = time.monotonic() + 60
    settings_seen = header_seen = False
    transaction = None
    content = bytearray()
    sequence = 0
    for _ in range(16384):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise ValueError('DFile receive deadline')
        header, payload = t.read_dfile_frame(process, min(5, remaining))
        kind, flags, session, trans = header
        counts = result.setdefault('dfile_frame_counts', {})
        counts[str(kind)] = counts.get(str(kind), 0) + 1
        frames = result.setdefault('dfile_receive_frames', [])
        if len(frames) < 16 or kind != 4:
            if len(frames) < 64:
                frames.append({'type': kind, 'flags': flags, 'bytes': len(payload)})
        if kind == 8 and not settings_seen:
            if len(payload) < 100 or struct.unpack_from('!H', payload, 2)[0] != 2 or not struct.unpack_from('!I', payload, 20)[0] & 0x100 or payload[91] != 1 or not struct.unpack_from('!I', payload, 96)[0] & 1:
                raise ValueError('unsupported encrypted WLAN DFile settings')
            send(t.dfile_settings())
            settings_seen = True
            result['dfile_encrypted_settings_agreed'] = True
        elif kind == 11:
            pass
        elif settings_seen and result.get('preview_ack_sent') and kind == 1 and not header_seen:
            decoded = t.dfile_decrypt_control(key, header, payload)
            fixture_header(decoded, expected)
            transaction = trans
            header_seen = True
            result['fixture_filename_and_size_verified'] = True
            send(t.dfile_encrypt_control(key, t.dfile_packet(2, 0, trans, struct.pack('!H', 1))))
            if expected.size == 0:
                finish(b'', trans)
        elif settings_seen and header_seen and trans == transaction and kind == 4 and not result.get('file_received'):
            chunk = decrypt_data_chunk(key, header, payload, sequence)
            if not chunk or len(content) + len(chunk) > expected.size:
                raise ValueError('fixture data exceeds declared bounds')
            is_end = len(content) + len(chunk) == expected.size
            if flags != (3 if is_end else (0 if sequence == 0 else 1)):
                raise ValueError('fixture data boundary flag differs')
            content.extend(chunk)
            sequence += 1
            result['data_chunks_verified'] = sequence
            result['received_progress_bytes'] = len(content)
            if is_end:
                finish(content, trans)
        elif result.get('file_received') and kind == 7 and trans == transaction:
            if t.dfile_decrypt_control(key, header, payload) != b'':
                raise ValueError('invalid DFile DONE ACK')
            result['dfile_done_ack_verified'] = True
            save()
            return
        else:
            raise ValueError('unsupported DFile receive stage')
        if kind != 4 or sequence % 256 == 0 or result.get('file_received'):
            save()
        yield
    raise ValueError('too many DFile frames')


def receive(t, process, device_hash, session_key, source, peer, processes, destination, result, save, expected=None, cancel_after_preview=False, publish_files=None, display_name='anDrop LAN Probe', node_id=None):
    expected = expected or FixtureSpec()
    a = t.auth
    def send(packet, target=process):
        target.stdin.write(packet)
        target.stdin.flush()
    def app(body):
        send(t.encrypted_frame(device_hash, session_key, body, 0))
    def channel(header, plain):
        send(t.channel_frame(session_key, header, plain, 0))
    def encoded(value):
        return json.dumps(value, separators=(',', ':')).encode() + b'\0'
    def listener():
        with socket.socket() as reservation:
            reservation.bind((source, 0))
            port = reservation.getsockname()[1]
        child = subprocess.Popen(['/usr/bin/nc', '-l', source, str(port)], stdin=subprocess.PIPE,
                                 stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        processes.append(child)
        return child, port
    def check_peer(child):
        r = subprocess.run(['/usr/sbin/lsof', '-nP', '-a', '-p', str(child.pid), '-iTCP', '-sTCP:ESTABLISHED', '-Fn'], capture_output=True, text=True, timeout=3)
        peers = [line.split('->', 1)[1].rsplit(':', 1)[0] for line in r.stdout.splitlines() if line.startswith('n') and '->' in line]
        if peers != [peer]:
            raise ValueError('incoming data peer differs from selected phone')
    def key_from(value):
        try:
            key = base64.b64decode(value.get('SESSION_KEY', ''), validate=True)
        except (ValueError, TypeError):
            raise ValueError('invalid channel key') from None
        if len(key) != 32:
            raise ValueError('unexpected channel key length')
        return key
    if destination.exists():
        raise ValueError('fixture destination already exists')
    app(a.tlv(1, a.tlv(1, b'user_confirm')))
    result['fixture_offer_accepted'] = True
    save()
    deadline = time.monotonic() + 90
    byte_process = file_process = file_key = byte_key = dfile_reader = None
    meta_started = False
    node_id = node_id or secrets.token_hex(32).upper()
    for _ in range(16424):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise ValueError('receive channels deadline')
        streams = [process.stdout] + [p.stdout for p in (byte_process, file_process) if p is not None]
        ready, _, _ = select.select(streams, [], [], min(8, remaining))
        if not ready:
            raise ValueError('receive channels response deadline')
        if file_process is not None and file_process.stdout in ready:
            if not result.get('file_peer_matches_target'):
                check_peer(file_process)
                result['file_peer_matches_target'] = True
            if dfile_reader is None:
                if hasattr(expected, 'entries'):
                    # Pass just the decoder; this module is also dynamically loaded.
                    from types import SimpleNamespace
                    dfile_reader = t.batch_files.receive(t, SimpleNamespace(decrypt_data_chunk=decrypt_data_chunk),
                        file_process, file_key, expected, destination, result, save, publish_files)
                else:
                    dfile_reader = receive_dfile(t, file_process, file_key, destination, result, save, expected)
            try:
                next(dfile_reader)
            except StopIteration:
                return
            continue
        if byte_process is not None and byte_process.stdout in ready:
            if byte_key is None:
                check_peer(byte_process)
                result['byte_peer_matches_target'] = True
            if byte_key is not None:
                try:
                    seq, flags, plain = read_bytes(byte_process, byte_key)
                except ByteChannelClosed:
                    if not result.get('preview_ack_sent'):
                        raise
                    # Image sharing closes its preview connection independently
                    # of DFile. Still require the file channel's verified DONE ACK.
                    result['byte_channel_closed_after_preview'] = True
                    byte_process = byte_key = None
                    save()
                    continue
                info = {'sequence': seq, 'flags': flags, 'bytes': len(plain), 'integrity_verified': True}
                body = t.decrypt_frame(a.frame(9, 0, plain), session_key)
                info['application_integrity_verified'] = True
                info['fixture_name_present'] = bool(expected.name) and expected.name in body
                info['tlvs'] = [{'tag': tag, 'bytes': len(value), 'fields': [{'tag': k, 'bytes': len(v)} for k, v in t.tlvs(value)]} for tag, value in t.tlvs(body)]
                result.setdefault('byte_data', []).append(info)
                save()
                fixture_preview(t, body, expected, diagnostics=result)
                if result.get('preview_ack_sent'):
                    result['preview_issue'] = 'repeated_preview'
                    raise ValueError('repeated fixture preview')
                if cancel_after_preview:
                    result['cancel_requested_after_preview'] = True
                    result['receiver_cancel_attempted'] = True
                    t.cancel_bytes(byte_process, device_hash, session_key, byte_key, result, save, sender=False)
                    return
                # Petal static PackPreviewAck: command 1 / field 8 = previewOK.
                # The application envelope is encrypted again within SoftBus bytes.
                reply = t.encrypted_frame(device_hash, session_key, a.tlv(1, a.tlv(8, b'previewOK')), 0)[24:]
                send(bytes_frame(byte_key, reply), byte_process)
                result['preview_ack_sent'] = True
                save()
                continue
            raw = a.read_frame(byte_process, 4)
            wrapped = a.frame(21, 0, raw)
            result.setdefault('byte_receive_frames', []).append(t.summarize_channel(wrapped, session_key))
            header, plain = t.decode_channel(wrapped, session_key)
            value = json.loads(plain.rstrip(b'\0'))
            if header[0] != a.MAGIC or header[1] != 6 or header[3] not in (0x90, 0x94) or value.get('CODE') != 1 or value.get('BUS_NAME') != 'IShareReceiverBytesSession':
                raise ValueError('unsupported byte channel request')
            byte_key = key_from(value)
            # SoftBus UnpackExternalDeviceReply requires identity, package and MTU.
            response = {'CODE': 1, 'API_VERSION': 2, 'MTU_SIZE': PREVIEW_MTU,
                        'DEVICE_ID': node_id, 'PKG_NAME': 'ohos.InterConnection.iShare',
                        'TRANS_CAPABILITY': 0, 'AUTH_STATE': ''}
            send(t.channel_frame(session_key, (header[0], 6, header[2], header[3] | 1, 0), encoded(response), 0)[24:], byte_process)
            result['byte_channel_ack_sent'] = True
            save()
            continue
        raw = a.read_frame(process, 4)
        if a.HEADER.unpack_from(raw)[1] == 9:
            body = t.decrypt_frame(raw, session_key)
            result.setdefault('post_offer_controls', []).append(t.summarize_control(body))
            for tag, value in t.tlvs(body):
                fields = dict(t.tlvs(value))
                if tag == 4:
                    if fields.get(4) not in (b'', peer.encode()):
                        raise ValueError('network request differs from selected LAN phone')
                    response = {1: b'', 2: b'', 3: b'true', 4: source.encode()}
                    app(a.tlv(5, b''.join(a.tlv(k, v) for k, v in response.items())))
                    result['lan_network_response_sent'] = True
                elif tag == 10:
                    if fields.get(1) != peer.encode():
                        raise ValueError('logical peer differs from selected LAN phone')
                    app(t.logical_connection(source))
                    meta = encoded({'DEVICE_NAME': display_name, 'DEVICE_TYPE_ID': 12, 'META_NODE_ID': node_id, 'FLAG': 100})
                    meta_started = True
                    result['logical_lan_exchange_complete'] = True
                elif tag == 1 and fields.get(1) in (b'senderCancel', b'receiverCancel', b'user_reject'):
                    raise ValueError('phone cancelled transfer')
                else:
                    raise ValueError('unsupported post-offer command')
        else:
            result.setdefault('receive_channels', []).append(t.summarize_channel(raw, session_key))
            header, plain = t.decode_channel(raw, session_key)
            if header[0] == t.META_INFO:
                t.meta_reply(header, plain, node_id)  # Validate peer structure.
                if not meta_started:
                    raise ValueError('unexpected metadata ordering')
                # Wait for sender metadata: sending ours immediately after command 10
                # can race HarmonyOS AuthMetaStartVerify and close the connection.
                channel((t.META_INFO, 5, 0, 0, 0), meta)
                result['pc_meta_info_sent'] = True
                channel((t.META_ACK, 5, header[2], 0, 0), t.META_ACK_TEXT)
                result['meta_ack_sent'] = True
            elif header[0] == t.META_ACK and plain == t.META_ACK_TEXT:
                result['meta_exchange_complete'] = True
            elif header[0] == 0xffff0004 and header[1] == 16 and header[3] == 0:
                value = json.loads(plain.rstrip(b'\0'))
                if value.get('CODE') != 3 or byte_process is not None:
                    raise ValueError('unexpected byte endpoint request')
                t.lan_endpoint(value, peer)
                byte_process, port = listener()
                channel((header[0], 16, header[2], 1, 0), t.verify_lan(source, port))
                result['byte_listener_advertised'] = True
            elif header[0] == 0xffff0004 and header[1] == 17 and header[3] == 0:
                value = json.loads(plain.rstrip(b'\0'))
                if value.get('CODE') != 1538 or value.get('MY_IP') != peer or value.get('BUS_NAME') != 'IShareReceiverFileSession' or value.get('BUSINESS_TYPE') != 3 or file_process is not None:
                    raise ValueError('unsupported file endpoint request')
                file_key = key_from(value)
                file_process, port = listener()
                response = {'MY_CHANNEL_ID': 1, 'P2P_PORT': port, 'MY_IP': source, 'CODE': 1538, 'STREAM_TYPE': 255,
                            'PKG_NAME': 'ohos.InterConnection.iShare', 'BUSINESS_TYPE': 3, 'API_VERSION': 0,
                            'TRANS_CAPABILITY': 0, 'UDP_CHANNEL_CAPABILITY': 0}
                channel((header[0], 17, header[2], 1, 0), encoded(response))
                result['file_listener_advertised'] = True
            else:
                raise ValueError('unsupported receive channel')
        save()
    raise ValueError('too many receive control frames')
