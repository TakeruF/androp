#!/usr/bin/env python3
"""Experimental LAN-only Huawei Share sender for explicitly selected files.

No Petal runtime, hotspot fallback, or saved keys. Synthetic fixture modes remain
available; --send-file snapshots only the explicitly supplied regular files.
"""
import argparse
import base64
import hashlib
import importlib.util
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import select
import socket
import struct
import subprocess
import sys
import time

spec = importlib.util.spec_from_file_location("huawei_auth_probe", Path(__file__).with_name("huawei-auth-probe.py"))
auth = importlib.util.module_from_spec(spec)
spec.loader.exec_module(auth)
batch_spec = importlib.util.spec_from_file_location('huawei_file_batch', Path(__file__).with_name('huawei-file-batch.py'))
batch_files = importlib.util.module_from_spec(batch_spec)
batch_spec.loader.exec_module(batch_files)


def tlvs(data):
    items, offset = [], 0
    while offset < len(data):
        if len(items) >= 32:
            raise ValueError("too many control fields")
        tag, offset = auth.read_varint(data, offset)
        size, offset = auth.read_varint(data, offset)
        if size > len(data) - offset:
            raise ValueError("truncated control field")
        items.append((tag, data[offset:offset + size]))
        offset += size
    return items


def encrypted_frame(device_hash, key, body, sequence):
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    nonce = secrets.token_bytes(16)
    metadata = auth.tlv(1, nonce)
    ciphertext = AESGCM(key).encrypt(nonce, body, None)
    envelope = (device_hash + b"\x81\xe5\x82" + auth.varint(len(metadata)) + metadata
                + auth.varint(len(ciphertext)) + ciphertext)
    return auth.frame(9, sequence, envelope)


def decrypt_frame(data, key):
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    from cryptography.exceptions import InvalidTag
    mode, ciphertext = auth.unpack_envelope(data)
    if mode != 2:
        raise ValueError("expected AES control response")
    payload = data[auth.HEADER.size:]
    offset = 16
    for _ in range(4):
        size, offset = auth.read_varint(payload, offset)
    nonce = auth.unwrap_tlv(payload[offset:offset + size], 1)
    if len(nonce) not in (12, 16):
        raise ValueError("unexpected AES nonce size")
    try:
        return AESGCM(key).decrypt(nonce, ciphertext, None)
    except InvalidTag:
        raise ValueError("control integrity verification failed") from None



def cancel_receive(process, device_hash, key, result, save):
    """Request receiver cancellation and verify its encrypted acknowledgement."""
    result['receiver_cancel_attempted'] = True
    result['receiver_cancel_ack_verified'] = False
    try:
        process.stdin.write(encrypted_frame(device_hash, key, auth.tlv(1, auth.tlv(4, b'receiverCancel')), 100))
        process.stdin.flush()
        result['receiver_cancel_sent'] = True
        deadline = time.monotonic() + 3
        for _ in range(8):
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            raw = auth.read_frame(process, remaining)
            if auth.HEADER.unpack_from(raw)[1] != 9:
                continue
            body = decrypt_frame(raw, key)
            result['receiver_cancel_response'] = summarize_control(body)
            if tlvs(body) == [(1, auth.tlv(5, b'receiverCancelACK'))]:
                result['receiver_cancel_ack_verified'] = True
                break
    except (OSError, ValueError):
        # Cleanup must never mask the original transfer failure.
        result.setdefault('receiver_cancel_sent', False)
    save()


def cancel_bytes(process, device_hash, session_key, byte_key, result, save, *, sender):
    """Test cancellation on the established, doubly encrypted byte channel."""
    spec = importlib.util.spec_from_file_location('huawei_receive_channels', Path(__file__).with_name('huawei-receive-channels.py'))
    framing = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(framing)
    field, text, ack_field, ack = ((2, b'senderCancel', 3, b'senderCancelACK') if sender
                                  else (4, b'receiverCancel', 5, b'receiverCancelACK'))
    result['byte_cancel_attempted'] = True
    result['byte_cancel_ack_verified'] = False
    try:
        inner = encrypted_frame(device_hash, session_key, auth.tlv(1, auth.tlv(field, text)), 100)[24:]
        process.stdin.write(framing.bytes_frame(byte_key, inner, 100))
        process.stdin.flush()
        result['byte_cancel_sent'] = True
        deadline = time.monotonic() + 4
        for _ in range(8):
            if time.monotonic() >= deadline:
                break
            _, _, response = framing.read_bytes(process, byte_key)
            body = decrypt_frame(auth.frame(9, 0, response), session_key)
            result.setdefault('byte_cancel_responses', []).append(summarize_control(body))
            if tlvs(body) == [(1, auth.tlv(ack_field, ack))]:
                result['byte_cancel_ack_verified'] = True
                break
    except (OSError, ValueError):
        result.setdefault('byte_cancel_sent', False)
    save()

def extension_summary(filenames):
    """Command 7/tag 7: extension -> count, not a display filename or MIME."""
    names = tuple(filenames)
    if not 1 <= len(names) <= batch_files.MAX_FILES:
        raise ValueError('invalid offer file count')
    counts = {}
    for name in names:
        batch_files.safe_name(name.encode('utf-8'))
        extension = Path(name).suffix.lower()
        counts[extension] = counts.get(extension, 0) + 1
    # HarmonyOS resolves these extensions through UtdClient. Keep unknown and
    # extensionless files honest; don't invent a PDF/Word type for them.
    return json.dumps(counts, separators=(',', ':'), sort_keys=True)


# Deliberately separate raster photos from video containers. A batch-level
# media declaration must never classify an accompanying video/document as a
# photo. Unknown formats (including RAW and vector files) stay ordinary files.
PHOTO_EXTENSIONS = frozenset({'.jpg', '.jpeg', '.jpe', '.png', '.heic', '.heif',
                              '.avif', '.webp', '.gif', '.bmp', '.tif', '.tiff'})
VIDEO_EXTENSIONS = frozenset({'.mp4', '.mov', '.m4v', '.3gp', '.3g2', '.avi',
                              '.mkv', '.webm', '.mpeg', '.mpg', '.mts', '.m2ts',
                              '.ts', '.wmv', '.flv'})


def offer_category(filenames):
    """Classify the whole selection, keeping photos and videos distinct."""
    kinds = set()
    for name in filenames:
        suffix = Path(name).suffix.lower()
        kinds.add('photo' if suffix in PHOTO_EXTENSIONS else
                  'video' if suffix in VIDEO_EXTENSIONS else 'file')
    return next(iter(kinds)) if len(kinds) == 1 else 'mixed'


def offer(filename, size, count=1, display_name='anDrop LAN Probe', *, filenames=None):
    # PackFileShareInfoPayload (0x1000995a8), outer command 7.
    # Tag 1 is sendType, not a MIME type. The Apple route's 1 selects
    # SendBean (the green image fallback); reserve it for photo-only batches.
    # 3 is the observed file route. Keep videos, documents and mixed batches
    # there with their real extension summary; no video-specific wire enum
    # has been established, so do not guess that 2 means video.
    # Tags 3/5/6 are itemCount/folderCount/fileCount; folders aren't supported.
    names = tuple(filenames) if filenames is not None else (filename,)
    if type(count) is not int or not 1 <= count <= batch_files.MAX_FILES or len(names) != count or names[0] != filename:
        raise ValueError('offer filenames do not match count or first file')
    # AppleRecvSession's tag-7 handler parses a JSON extension/count object
    # and calls GetUniformDataTypeByFilenameExtension for each key. Sending
    # a raw filename here leaves the receiver's type summary empty.
    send_type = '1' if offer_category(names) == 'photo' else '3'
    fields = {1: send_type, 2: display_name, 3: str(count), 4: str(size),
              5: "0", 6: str(count), 7: extension_summary(names), 16: "0"}
    return auth.tlv(7, b"".join(auth.tlv(k, v.encode()) for k, v in fields.items()))


def file_preview(filenames):
    """Command 8/tag 11 carries names separately from the offer's type counts."""
    names = tuple(filenames)
    extension_summary(names)  # Same count and UTF-8 basename bounds as the offer.
    # Petal SendFilePreview joins names with '|'. This field is advisory;
    # DFile still carries every exact filename, including a literal '|'.
    # Native Petal PackFilePreviewPayload always includes the parallel media
    # arrays (tag 13), even when timestamps are unavailable. HarmonyOS parses
    # that field together with tag 11 to build its filename metadata map.
    # -1 / empty string are Petal's unknown values; don't invent photo dates.
    metadata = json.dumps({'date_added': [-1] * len(names),
                           'date_taken': [-1] * len(names),
                           'detail_time': [''] * len(names)}, separators=(',', ':')).encode()
    return auth.tlv(8, auth.tlv(11, '|'.join(names).encode('utf-8')) + auth.tlv(13, metadata))


def send_file_preview(process, device_hash, session_key, byte_key, filenames, result, save):
    # Preview advances Huawei's receive state beyond SessionOpenedEvent's
    # accepted states. Open the file transport first so RegisterFileSchema
    # installs its destination-file callbacks before this state transition.
    if not result.get('file_channel_acknowledged') or not result.get('dfile_settings_verified'):
        raise ValueError('file transport must be ready before preview')
    spec = importlib.util.spec_from_file_location('huawei_receive_channels', Path(__file__).with_name('huawei-receive-channels.py'))
    framing = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(framing)
    inner = encrypted_frame(device_hash, session_key, file_preview(filenames), 0)[24:]
    process.stdin.write(framing.bytes_frame(byte_key, inner))
    process.stdin.flush()
    result['file_preview_sent'] = True
    save()
    # Huawei can send its avatar (command 1 / tag 15) on this channel
    # before previewOK. Petal handles that notification separately. Discard
    # only this bounded, authenticated auxiliary payload; never save it or
    # mistake it for approval to transmit the files.
    for _ in range(4):
        _, _, response = framing.read_bytes(process, byte_key)
        body = decrypt_frame(auth.frame(9, 0, response), session_key)
        result.setdefault('file_preview_responses', []).append(summarize_control(body))
        save()
        commands = tlvs(body)
        if commands == [(1, auth.tlv(8, b'previewOK'))]:
            result['file_preview_ack_verified'] = True
            save()
            return
        fields = tlvs(commands[0][1]) if len(commands) == 1 and commands[0][0] == 1 else []
        if len(fields) != 1 or fields[0][0] != 15 or len(fields[0][1]) > 65536:
            raise ValueError('file preview was not acknowledged')
    raise ValueError('file preview acknowledgement limit exceeded')


CONTROL_VALUES = {b"user_confirm", b"user_reject", b"senderCancel", b"senderCancelACK",
                  b"receiverCancel", b"receiverCancelACK", b"next_recv", b"previewOK"}


def summarize_control(body, integrity_verified=True):
    commands = []
    for tag, value in tlvs(body):
        fields = []
        for field_tag, field_value in tlvs(value):
            field = {"tag": field_tag, "bytes": len(field_value)}
            if tag == 1 and field_value in CONTROL_VALUES:
                field["control"] = field_value.decode("ascii")
            fields.append(field)
        commands.append({"tag": tag, "bytes": len(value), "fields": fields})
    return {"integrity_verified": integrity_verified, "commands": commands}


def logical_connection(address):
    # Command 10 advertises only the existing LAN address. No AP credentials.
    if not auth.private_ipv4(address):
        raise ValueError("logical address must be private IPv4")
    return auth.tlv(10, auth.tlv(1, address.encode("ascii")))


def network_request(address):
    if not auth.private_ipv4(address):
        raise ValueError("network address must be private IPv4")
    # PackNetworkInfoReq: current SSID, unused field, SSID, existing IP.
    # SSID is unavailable under this process's location permission. Leave it empty.
    return auth.tlv(4, b"".join(auth.tlv(k, v) for k, v in
                              [(1, b""), (2, b""), (3, b""), (4, address.encode("ascii"))]))


META_INFO = 0xFFFF0002
META_ACK = 0xFFFF0008
META_ACK_TEXT = b"META_DEVICE_INFO_ACK\0"


def decode_channel(data, key):
    """Validate the observed LAN auth header and authenticated payload."""
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    from cryptography.exceptions import InvalidTag
    if len(data) < 2 * auth.HEADER.size + 28:
        raise ValueError("truncated channel frame")
    outer = auth.HEADER.unpack_from(data)
    if outer[0] != auth.MAGIC or outer[1] != 21 or outer[4] != len(data) - 24:
        raise ValueError("invalid channel framing")
    header = auth.HEADER.unpack_from(data, 24)
    if header[4] != len(data) - 48:
        raise ValueError("invalid inner channel length")
    try:
        plain = AESGCM(key).decrypt(data[48:60], data[60:], None)
    except InvalidTag:
        raise ValueError("channel integrity verification failed") from None
    return header, plain


def channel_frame(key, header, plain, sequence):
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    nonce = secrets.token_bytes(12)
    payload = nonce + AESGCM(key).encrypt(nonce, plain, None)
    inner = auth.HEADER.pack(*header[:4], len(payload))
    return auth.frame(21, sequence, inner + payload)


def meta_reply(header, plain, node_id, display_name='anDrop LAN Probe'):
    if header[0] == META_INFO:
        value = json.loads(plain.removesuffix(b"\0"))
        expected = {"DEVICE_NAME": str, "DEVICE_TYPE_ID": int, "META_NODE_ID": str, "FLAG": int}
        if not isinstance(value, dict) or any(type(value.get(k)) is not t for k, t in expected.items()):
            raise ValueError("invalid MetaNode device info")
        return json.dumps({"DEVICE_NAME": display_name, "DEVICE_TYPE_ID": 12,
                           "META_NODE_ID": node_id, "FLAG": 100}, separators=(",", ":")).encode()
    if header[0] == META_ACK and plain == META_ACK_TEXT:
        return META_ACK_TEXT
    return None


def verify_lan(address, port):
    if not auth.private_ipv4(address) or not 1 <= port <= 65535:
        raise ValueError("invalid existing LAN endpoint")
    return json.dumps({"CODE": 3, "P2P_IP": address, "P2P_PORT": port,
                       "PROTOCOL_TYPE": 4}, separators=(",", ":")).encode() + b"\0"


def lan_endpoint(value, expected_ip):
    address, port = value.get("P2P_IP"), value.get("P2P_PORT")
    if address != expected_ip or not auth.private_ipv4(address) or type(port) is not int or not 1 <= port <= 65535:
        raise ValueError("channel endpoint differs from explicit LAN phone")
    return address, port


def bytes_handshake(key, identity, byte_key):
    fields = {"CODE": 1, "API_VERSION": 2, "BUS_NAME": "IShareReceiverBytesSession",
              "CLIENT_BUS_NAME": "IShareSenderBytesSession", "PKG_NAME": "ohos.InterConnection.iShare",
              "MTU_SIZE": 4194304, "TRANS_CAPABILITY": 0, "ROUTE_TYPE": 2,
              "DEVICE_ID": identity, "BUSINESS_TYPE": 1, "TRANS_FLAGS": 2,
              "SESSION_KEY": base64.b64encode(byte_key).decode()}
    plain = json.dumps(fields, separators=(",", ":")).encode() + b"\0"
    return channel_frame(key, (auth.MAGIC, 6, secrets.randbits(64), 0x94, 0), plain, 0)[24:]


def file_handshake(address, identity, file_key):
    fields = {"MY_CHANNEL_ID": 1, "MY_IP": address, "DEVICE_ID": identity,
              "CODE": 1538, "API_VERSION": 2, "BUSINESS_TYPE": 3, "STREAM_TYPE": 255,
              "CHANNEL_TYPE": 1, "UDP_CONN_TYPE": 1, "BUS_NAME": "IShareReceiverFileSession",
              "CLIENT_BUS_NAME": "IShareSenderFileSession", "PKG_NAME": "ohos.InterConnection.iShare",
              "TRANS_CAPABILITY": 0, "SESSION_KEY": base64.b64encode(file_key).decode()}
    return json.dumps(fields, separators=(",", ":")).encode() + b"\0"


def read_dfile_frame(process, seconds=4):
    deadline = time.monotonic() + seconds
    def exact(size):
        data = bytearray()
        while len(data) < size:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([process.stdout], [], [], remaining)[0]:
                raise ValueError("DFile response deadline")
            chunk = os.read(process.stdout.fileno(), size - len(data))
            if not chunk:
                raise ValueError("DFile connection closed")
            data.extend(chunk)
        return bytes(data)
    header = exact(8)
    kind, flags, session, transaction, size = struct.unpack("!BBHHH", header)
    if not 1 <= kind <= 14 or size > 14720:
        raise ValueError("invalid DFile framing")
    return (kind, flags, session, transaction), exact(size)


def dfile_settings(encrypt_headers=True):
    # WLAN, AES-GCM; control encryption is capsCheck bit 8, independently
    # of the headerEnc byte that protects the metadata inside file data.
    payload = struct.pack("!HHIIIII", 1472, 2, 1, 0, 0, 1472, 0x100 if encrypt_headers else 0) + bytes(67) + bytes([int(encrypt_headers)]) + struct.pack("!II", 0, 1)
    return struct.pack("!BBHHH", 8, 0, 0, 0, len(payload)) + payload


def dfile_packet(kind, flags, transaction, payload):
    if not 1 <= kind <= 14 or not 0 <= transaction <= 65535 or len(payload) > 14720:
        raise ValueError("invalid outgoing DFile frame")
    return struct.pack("!BBHHH", kind, flags, 0, transaction, len(payload)) + payload


def dfile_file_header(filename, size):
    if not ((re.fullmatch(r"androp-independent-[0-9]{6}\.txt", filename) and size == 60)
            or (re.fullmatch(r"androp-empty-[0-9]{6}\.txt", filename) and size == 0)
            or (re.fullmatch(r"華為共有検証-独立-[0-9]{6}-8MiB\.bin", filename) and size == 8 * 1024 * 1024)):
        raise ValueError("only the synthetic 0 B, 60 B or 8 MiB fixture is allowed")
    name = filename.encode("utf-8")
    return dfile_packet(1, 0, 1, struct.pack("!HHQH", 1, 1, size, len(name)) + name)


def dfile_encrypt_control(key, packet):
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    kind, flags, session, transaction, size = struct.unpack_from("!BBHHH", packet)
    if size != len(packet) - 8:
        raise ValueError("invalid DFile inner frame length")
    nonce = secrets.token_bytes(12)
    plain = struct.pack("!Q", time.monotonic_ns() // 1000) + packet
    # DFile SetSessionCryptPara uses the first 16 bytes for AES-GCM.
    encrypted = AESGCM(key[:16]).encrypt(nonce, plain, b"A" * 64) + nonce
    return struct.pack("!BBHHH", kind, flags, session, transaction, len(encrypted)) + encrypted


def dfile_decrypt_control(key, header, payload):
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    from cryptography.exceptions import InvalidTag
    if len(payload) < 44:
        raise ValueError("truncated encrypted DFile control")
    try:
        plain = AESGCM(key[:16]).decrypt(payload[-12:], payload[:-12], b"A" * 64)
    except InvalidTag:
        raise ValueError("DFile control integrity verification failed") from None
    inner = struct.unpack_from("!BBHHH", plain, 8)
    if inner[:4] != header or inner[4] != len(plain) - 16:
        raise ValueError("DFile authenticated header mismatch")
    return plain[16:]


def dfile_file_data(key, content, encrypt_headers=True):
    if content != b"anDrop independent Huawei Share LAN test. No personal data.\n":
        raise ValueError("only the synthetic fixture is allowed")
    return dfile_data_chunk(key, content, 0, 3, encrypt_headers)


def dfile_data_chunk(key, content, sequence, flags, encrypt_headers=True, file_id=1):
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    if not 1 <= len(content) <= 1422 or not 0 <= sequence < 2 ** 32 or flags not in (0, 1, 3) or not 1 <= file_id <= 16:
        raise ValueError("invalid bounded DFile data chunk")
    nonce = secrets.token_bytes(12)
    # DFile uses ciphertext + tag + nonce, with 64 ASCII A bytes as AAD.
    plain = (struct.pack("!HIH", file_id, sequence, 1) if encrypt_headers else b"") + content
    payload = struct.pack("!HI", file_id, sequence) + AESGCM(key[:16]).encrypt(nonce, plain, b"A" * 64) + nonce
    return dfile_packet(4, flags, 1, payload)


class FixtureCancelled(ValueError):
    pass


def send_dfile_fixture(process, key, filename, content, result, save, encrypt_headers=True, cancel_after_chunks=0):
    # Validate the whole synthetic source before writing any frame.
    header_packet = dfile_file_header(filename, len(content))
    if content and content != b"anDrop independent Huawei Share LAN test. No personal data.\n":
        if len(content) != 8 * 1024 * 1024 or hashlib.sha256(content).hexdigest() != '7d212b9c884f5c77896de960ae17cc341cda43b14d6a971f34ca29ebd4badf7f':
            raise ValueError('synthetic large fixture digest differs')
    if cancel_after_chunks and not 1 <= cancel_after_chunks < (len(content) + 1421) // 1422:
        raise ValueError('cancellation must precede the final data frame')
    deadline = time.monotonic() + 60
    try:
        output_fd = process.stdin.fileno()
    except (AttributeError, OSError):
        output_fd = None  # In-memory offline protocol tests.
    if output_fd is not None:
        os.set_blocking(output_fd, False)
    def send(packet):
        if output_fd is None:
            process.stdin.write(packet)
            process.stdin.flush()
            return
        view = memoryview(packet)
        while view:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([], [output_fd], [], remaining)[1]:
                raise ValueError('DFile send deadline')
            try:
                count = os.write(output_fd, view)
            except BlockingIOError:
                continue
            if count <= 0:
                raise ValueError('DFile send pipe closed')
            view = view[count:]
    def control(packet):
        return dfile_encrypt_control(key, packet) if encrypt_headers else packet
    send(control(header_packet))
    result["dfile_header_sent"] = True
    result["dfile_transfer_responses"] = []
    while time.monotonic() < deadline and len(result["dfile_transfer_responses"]) < 32:
        header, payload = read_dfile_frame(process, max(.01, deadline - time.monotonic()))
        kind, flags, session, transaction = header
        entry = {"type": kind, "flags": flags, "session": session, "transaction": transaction,
                 "payload_bytes": len(payload)}
        result["dfile_transfer_responses"].append(entry)
        if kind == 9 and len(payload) == 2:
            entry["reset_code"] = struct.unpack("!H", payload)[0]
            entry["integrity_verified"] = False
            save()
            raise ValueError("DFile receiver reset before encrypted exchange")
        if kind not in (2, 3, 5, 6, 7, 9):
            entry["integrity_verified"] = False
            save()
            continue
        if kind == 2 and not payload:
            entry["integrity_verified"] = False
            entry["empty_header_confirmation_ignored"] = True
            save()
            continue
        if encrypt_headers:
            payload = dfile_decrypt_control(key, header, payload)
        entry["integrity_verified"] = encrypt_headers
        if kind == 5 and len(payload) == 6:
            entry["ack_word16"], entry["ack_word32"] = struct.unpack("!HI", payload)
        if kind == 9 and len(payload) >= 2:
            entry["reset_code"] = struct.unpack_from("!H", payload)[0]
        save()
        if session != 0 or transaction != 1:
            continue
        if kind in (2, 3) and payload == b"\x00\x01" and not result.get("file_data_stage_complete"):
            if content:
                for sequence, offset in enumerate(range(0, len(content), 1422)):
                    chunk = content[offset:offset + 1422]
                    flags = 3 if offset + len(chunk) == len(content) else (0 if sequence == 0 else 1)
                    send(dfile_data_chunk(key, chunk, sequence, flags, encrypt_headers))
                    result['data_chunks_sent'] = sequence + 1
                    result['data_bytes_queued'] = offset + len(chunk)
                    if cancel_after_chunks and sequence + 1 == cancel_after_chunks:
                        result['cancel_requested_during_data'] = True
                        save()
                        raise FixtureCancelled('intentional synthetic transfer cancellation')
                    if sequence % 256 == 0:
                        save()
                result["file_data_sent"] = True
            else:
                result["empty_file_no_data_frame"] = True
            result["file_data_stage_complete"] = True
            save()
        elif kind == 6 and payload == b"\x00\x01" and result.get("file_data_stage_complete"):
            send(control(dfile_packet(7, 0, 1, b"")))
            result["dfile_transfer_done_received"] = True
            result["dfile_done_ack_sent"] = True
            return
        elif kind == 9:
            raise ValueError("DFile receiver reset transfer")
    raise ValueError("DFile completion not received")


def summarize_channel(data, key):
    summary = auth.summarize(data)
    if summary["module"] != 21:
        return summary
    try:
        header, plain = decode_channel(data, key)
    except ValueError:
        summary["integrity_verified"] = False
        return summary
    summary.update(inner_type=hex(header[0]), inner_module=header[1], inner_flags=header[3],
                   nonce_prefix_bytes=24, nonce_bytes=12)
    summary["integrity_verified"] = True
    if plain == META_ACK_TEXT:
        summary["control"] = "META_DEVICE_INFO_ACK"
        return summary
    try:
        value = json.loads(plain.rstrip(b"\0"))
    except (ValueError, UnicodeError):
        summary["plaintext_bytes"] = len(plain)
        return summary
    if not isinstance(value, dict):
        raise ValueError("file channel metadata must be an object")
    summary["structural_fields"] = [
        {"name": k, "kind": type(v).__name__, **({"bytes": len(v.encode())} if isinstance(v, str) else {})}
        for k, v in value.items() if re.fullmatch(r"[A-Za-z_][A-Za-z_0-9]{0,39}", k)
    ]
    allowed = {"CODE", "API_VERSION", "BUSINESS_TYPE", "STREAM_TYPE", "CHANNEL_TYPE",
               "UDP_CONN_TYPE", "TRANS_CAPABILITY", "MY_CHANNEL_ID", "PEER_CHANNEL_ID",
               "MY_PORT", "ERR_CODE", "MTU_SIZE", "DEVICE_TYPE_ID", "FLAG", "P2P_PORT", "PROTOCOL_TYPE"}
    summary["numeric_fields"] = {k: v for k, v in value.items() if k in allowed and type(v) is int}
    summary["known_fields"] = sorted(set(value) & (allowed | {"SESSION_KEY", "MY_IP", "DEVICE_ID",
                                    "BUS_NAME", "CLIENT_BUS_NAME", "PKG_NAME"}))
    for k in ("BUS_NAME", "CLIENT_BUS_NAME"):
        if value.get(k) in ("IShareSenderFileSession", "IShareReceiverFileSession"):
            summary[k.lower()] = value[k]
    return summary


def main():
    from cryptography.hazmat.primitives.asymmetric import rsa
    from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--peer-ip", required=True)
    parser.add_argument("--port", required=True, type=int)
    parser.add_argument("--seconds", type=int, default=40)
    parser.add_argument("--logical-lan", action="store_true", help="send existing LAN IP after explicit receiver acceptance")
    parser.add_argument("--network-lan", action="store_true", help="request network metadata before sending the existing LAN IP")
    parser.add_argument("--dfile-settings", action="store_true", help="experimental DFile settings exchange after file-channel approval; no file bytes")
    parser.add_argument("--dfile-plain-headers", action="store_true", help="explicit experimental plaintext DFile headers; file content remains AES-GCM encrypted")
    parser.add_argument("--send-fixture", action="store_true", help="send only the fixed synthetic 60-byte fixture over DFile")
    parser.add_argument("--output", type=Path, required=True, help="redacted research log")
    parser.add_argument("--send-empty-fixture", action="store_true", help="send a synthetic empty text file over DFile")
    parser.add_argument("--send-large-fixture", action="store_true", help="send a synthetic Japanese-named 8 MiB file")
    parser.add_argument("--cancel-after-chunks", type=int, default=0, help="cancel the large fixture before its final chunk (test only)")
    parser.add_argument("--cancel-via-bytes", action="store_true", help="test cancellation on the established byte channel")
    parser.add_argument('--send-file', type=Path, action='append', help='explicit local file; up to 16 files, 4 GiB each / 16 GiB total, streamed from disk')
    parser.add_argument('--display-name', default='anDrop LAN Probe')
    parser.add_argument('--identity-key', type=Path, help='owner-only RSA key naming this Mac across runs; created if absent')
    args = parser.parse_args()
    if not 1 <= len(args.display_name) <= 100 or any(ord(c) < 32 for c in args.display_name):
        parser.error('invalid display name')
    batch = None
    if args.send_file:
        if args.send_fixture or args.send_empty_fixture or args.send_large_fixture or args.cancel_after_chunks or args.dfile_plain_headers:
            parser.error('explicit files cannot be combined with synthetic fixtures, cancellation, or plaintext headers')
        batch = batch_files.Batch.from_paths(args.send_file)
        args.send_fixture = True
    if args.send_empty_fixture and args.send_large_fixture:
        parser.error("select only one fixture")
    if args.cancel_after_chunks and (not args.send_large_fixture or not 1 <= args.cancel_after_chunks < 5900):
        parser.error("cancellation requires the large fixture and 1..5899 chunks")
    if args.cancel_via_bytes and not args.cancel_after_chunks:
        parser.error("byte cancellation requires an intentional mid-data cancellation")
    if args.send_empty_fixture or args.send_large_fixture:
        args.send_fixture = True
    if not auth.private_ipv4(args.peer_ip) or not 1 <= args.port <= 65535 or not 1 <= args.seconds <= 60:
        parser.error("invalid private endpoint or duration")
    route = subprocess.run(["/sbin/route", "-n", "get", args.peer_ip], capture_output=True, text=True, timeout=3)
    source = next((x for x in auth.interfaces() if x.interface == "en0" and ipaddress.ip_address(args.peer_ip) in x.network), None)
    if source is None or source.address == args.peer_ip or not any(x.strip() == "interface: en0" for x in route.stdout.splitlines()):
        parser.error("test phone must be reached through the existing en0 LAN")
    content = b"anDrop independent Huawei Share LAN test. No personal data.\n"
    filename = f"androp-independent-{time.strftime('%H%M%S')}.txt"
    if args.send_empty_fixture:
        content = b""
        filename = f"androp-empty-{time.strftime('%H%M%S')}.txt"
    if args.send_large_fixture:
        content = bytes(range(256)) * 32768
        filename = f"華為共有検証-独立-{time.strftime('%H%M%S')}-8MiB.bin"
    result = {"file_name": filename, "file_bytes": len(content), "file_sha256": hashlib.sha256(content).hexdigest(),
              "file_data_sent": False, "responses": []}
    if batch:
        filename = batch.name.decode('utf-8')
        result = {'file_count': batch.count, 'total_bytes': batch.size, 'file_data_sent': False, 'responses': [],
                  'files': [{'file_id': i, 'name_bytes': len(e.name), 'bytes': e.size, 'sha256': e.sha256}
                            for i, e in enumerate(batch.entries, 1)]}
    # Keep the synthetic source as an integrity reference for later data tests.
    args.output.parent.mkdir(parents=True, exist_ok=True)
    if not batch:
        with (args.output.parent / filename).open('xb') as fixture:
            fixture.write(content)
    def save():
        args.output.write_text(json.dumps(result, indent=2) + "\n")
    if args.identity_key:
        private_key = auth.load_identity_key(args.identity_key)
    else:
        private_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    public_der = private_key.public_key().public_bytes(Encoding.DER, PublicFormat.SubjectPublicKeyInfo)
    digest = auth.key_hash(public_der)
    device_hash = digest[:8].hex().upper().encode()
    identity = "".join(f"{word:04X}" for word in struct.unpack("<HHH", digest[:6]))
    # Authentication and preview channels can be quiet while a large file flows
    # on its separate socket. The DATA sender enforces its own 60 s idle limit.
    control_idle = '86400' if batch else str(args.seconds + 5)
    process = subprocess.Popen(["/usr/bin/nc", "-G", "3", "-w", control_idle, args.peer_ip, str(args.port)],
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    def send(packet):
        process.stdin.write(packet)
        process.stdin.flush()
    keys = []
    channels = []
    node_id = auth.meta_node_id(public_der) if args.identity_key else secrets.token_hex(32).upper()
    result['persistent_identity'] = bool(args.identity_key)
    try:
        result["stage"] = "auth_opening"
        send(auth.opening(identity))
        opening = auth.summarize(auth.read_frame(process))
        if opening.get("code") != 4 or opening["module"] != 8 or opening["flags"] != 1:
            raise ValueError("auth channel opening failed")
        result["auth_opened"] = True
        result["stage"] = "capabilities"
        send(auth.capabilities(device_hash))
        capabilities = auth.read_frame(process)
        result["capability_response"] = auth.summarize(capabilities)
        capability_mode, capability_body = auth.unpack_envelope(capabilities)
        if capability_mode != 0 or not any(tag == 3 for tag, _ in tlvs(capability_body)):
            if capability_mode == 0:
                result["preauth_control"] = summarize_control(capability_body, integrity_verified=False)
                result["preauth_busy_signal"] = b"busy" in capability_body.lower()
            raise ValueError("peer did not acknowledge capability request")
        result["stage"] = "public_key"
        send(auth.envelope_frame(device_hash, auth.tlv(6, auth.tlv(1, public_der)), 3))
        peer_key = auth.read_frame(process, 15)
        result["stage"] = "key_challenge"
        result["key_challenge"] = auth.challenge(process, device_hash, peer_key, capabilities, private_key, keys.append)
        send(encrypted_frame(device_hash, keys[0], offer(
            filename, batch.size if batch else len(content), batch.count if batch else 1, args.display_name,
            filenames=[entry.name.decode('utf-8') for entry in batch.entries] if batch else None), 5))
        result["offer_sent"] = True
        result["stage"] = "offer_and_channels"
        save()
        print("Encrypted synthetic-file offer sent; awaiting phone control response.", flush=True)
        deadline = time.monotonic() + args.seconds
        sequence = 6
        while time.monotonic() < deadline and len(result["responses"]) < 16:
            raw = auth.read_frame(process, max(.01, deadline - time.monotonic()))
            if auth.HEADER.unpack(raw[:auth.HEADER.size])[1] != 9:
                result["responses"].append(summarize_channel(raw, keys[0]))
                save()
                print(json.dumps(result["responses"][-1]), flush=True)
                header, plain = decode_channel(raw, keys[0])
                reply = meta_reply(header, plain, node_id, args.display_name)
                if reply is None:
                    value = json.loads(plain.removesuffix(b"\0"))
                    if header[0] == 0xffff0004 and header[1] == 16 and header[3] == 1 and value.get("CODE") == 3:
                        address, port = lan_endpoint(value, args.peer_ip)
                        result["lan_port_verified"] = True
                        byte_process = subprocess.Popen(["/usr/bin/nc", "-G", "3", "-w", control_idle, address, str(port)],
                                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
                        channels.append(byte_process)
                        keys.append(secrets.token_bytes(32))
                        byte_process.stdin.write(bytes_handshake(keys[0], identity, keys[-1]))
                        byte_process.stdin.flush()
                        result["byte_handshake_sent"] = True
                        save()
                        byte_raw = auth.read_frame(byte_process, 5)
                        wrapped = auth.frame(21, 0, byte_raw)
                        result["byte_response"] = summarize_channel(wrapped, keys[0])
                        print(json.dumps(result["byte_response"]), flush=True)
                        byte_header, byte_plain = decode_channel(wrapped, keys[0])
                        byte_value = json.loads(byte_plain.removesuffix(b"\0"))
                        if byte_header[1] != 6 or byte_header[3] != 0x95 or byte_value.get("CODE") != 1 or "ERR_CODE" in byte_value:
                            raise ValueError("byte handshake was not acknowledged")
                        result["byte_channel_acknowledged"] = True
                        keys.append(secrets.token_bytes(32))
                        send(channel_frame(keys[0], (0xffff0004, 17, secrets.randbits(64), 0, 0),
                                           file_handshake(source.address, identity, keys[-1]), sequence))
                        sequence += 1
                        result["file_channel_request_sent"] = True
                        save()
                        continue
                    if header[0] == 0xffff0004 and header[1] == 17 and header[3] == 1 and value.get("CODE") == 1538:
                        address, port = lan_endpoint({"P2P_IP": value.get("MY_IP"), "P2P_PORT": value.get("P2P_PORT")}, args.peer_ip)
                        result["file_channel_acknowledged"] = True
                        result["file_endpoint_matches_test_phone"] = True
                        result["status"] = "file_channel_negotiated"
                        save()
                        if not (args.dfile_settings or args.send_fixture):
                            break
                        file_process = subprocess.Popen(["/usr/bin/nc", "-G", "3", "-w", "60", address, str(port)],
                                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
                        channels.append(file_process)
                        file_process.stdin.write(dfile_settings(not args.dfile_plain_headers))
                        result["dfile_header_encryption_requested"] = not args.dfile_plain_headers
                        file_process.stdin.flush()
                        result["dfile_settings_sent"] = True
                        frame_header, payload = read_dfile_frame(file_process)
                        result["dfile_response"] = {"type": frame_header[0], "flags": frame_header[1], "payload_bytes": len(payload)}
                        if frame_header[0] == 8 and len(payload) >= 24:
                            values = struct.unpack_from("!HHIIIII", payload)
                            result["dfile_response"].update(dict(zip(("mtu", "connection_type", "version", "abm_capability", "capability", "data_frame_size", "caps_check"), values)))
                            if len(payload) >= 92:
                                result["dfile_response"]["header_encryption"] = payload[91]
                            if len(payload) >= 100:
                                result["dfile_response"]["cipher_capability"] = struct.unpack_from("!I", payload, 96)[0]
                        result["status"] = "dfile_response_observed"
                        print(json.dumps(result["dfile_response"]), flush=True)
                        if args.send_fixture:
                            settings = result["dfile_response"]
                            if (frame_header[0] != 8 or settings.get("connection_type") != 2
                                or not settings.get("cipher_capability", 0) & 1
                                or (not args.dfile_plain_headers and
                                    (settings.get("header_encryption") != 1 or not settings.get("caps_check", 0) & 0x100))):
                                raise ValueError("unsupported DFile settings")
                            result['dfile_settings_verified'] = True
                            send_file_preview(byte_process, device_hash, keys[0], keys[-2],
                                              [entry.name.decode('utf-8') for entry in batch.entries] if batch else [filename],
                                              result, save)
                            if batch:
                                batch_files.send(sys.modules[__name__], file_process, keys[-1], batch, result, save)
                            else:
                                send_dfile_fixture(file_process, keys[-1], filename, content, result, save,
                                                   not args.dfile_plain_headers, args.cancel_after_chunks)
                            result["status"] = "dfile_batch_completed" if batch else "dfile_fixture_completed"
                            save()
                            # Allow the DONE_ACK to drain through nc and observe any
                            # application-layer completion without asserting it exists.
                            try:
                                completion = auth.read_frame(process, 2)
                                if auth.HEADER.unpack_from(completion)[1] == 9:
                                    result["post_transfer_control"] = summarize_control(decrypt_frame(completion, keys[0]))
                            except (OSError, ValueError):
                                result["post_transfer_control_observed"] = False
                        break
                    result["status"] = "channel_frame_observed"
                    break
                send(channel_frame(keys[0], header, reply, sequence))
                sequence += 1
                result["pc_metadata_sent" if header[0] == META_INFO else "metadata_ack_sent"] = True
                if header[0] == META_ACK and not result.get("lan_port_request_sent"):
                    # The native sender reserves then releases an ephemeral local port.
                    with socket.socket() as reservation:
                        reservation.bind((source.address, 0))
                        local_port = reservation.getsockname()[1]
                    verify_header = (0xffff0004, 16, secrets.randbits(64), 0, 0)
                    send(channel_frame(keys[0], verify_header, verify_lan(source.address, local_port), sequence))
                    sequence += 1
                    result["lan_port_request_sent"] = True
                save()
                continue
            body = decrypt_frame(raw, keys[0])
            result["responses"].append(summarize_control(body))
            controls = [v for tag, value in tlvs(body) if tag == 1 for _, v in tlvs(value)]
            if b"user_reject" in controls or b"receiverCancel" in controls:
                result["status"] = "receiver_declined_or_cancelled"
                save()
                print(json.dumps(result["responses"][-1]), flush=True)
                break
            if (1, auth.tlv(1, b"user_confirm")) in tlvs(body):
                result["receiver_accepted"] = True
                if args.network_lan and not result.get("network_request_sent"):
                    send(encrypted_frame(device_hash, keys[0], network_request(source.address), sequence))
                    sequence += 1
                    result["network_request_sent"] = True
                elif args.logical_lan and not result.get("logical_lan_sent"):
                    send(encrypted_frame(device_hash, keys[0], logical_connection(source.address), sequence))
                    sequence += 1
                    result["logical_lan_sent"] = True
            if any(tag == 5 for tag, _ in tlvs(body)) and args.network_lan:
                result["network_response_received"] = True
                if not result.get("logical_lan_sent"):
                    send(encrypted_frame(device_hash, keys[0], logical_connection(source.address), sequence))
                    sequence += 1
                    result["logical_lan_sent"] = True
            for tag, value in tlvs(body):
                if tag == 10:
                    fields = dict(tlvs(value))
                    matches = fields.get(1) == args.peer_ip.encode("ascii")
                    result["logical_peer_matches_test_phone"] = matches
                    if not matches:
                        raise ValueError("logical peer does not match explicit LAN test phone")
            save()
            print(json.dumps(result["responses"][-1]), flush=True)
    except FixtureCancelled:
        result['status'] = 'cancelled_by_probe'
        if args.cancel_via_bytes:
            cancel_bytes(byte_process, device_hash, keys[0], keys[1], result, save, sender=True)
    except (OSError, ValueError) as error:
        result.update(status="incomplete", error_type=type(error).__name__)
        if type(error) is ValueError:
            result["error_reason"] = str(error)
    finally:
        if (keys and result.get("receiver_accepted") and not result.get("dfile_transfer_done_received")
            and result.get("status") != "receiver_declined_or_cancelled" and not result.get('byte_cancel_attempted')):
            result["cleanup_cancel_acknowledged"] = False
            try:
                send(encrypted_frame(device_hash, keys[0], auth.tlv(1, auth.tlv(2, b"senderCancel")), 100))
                result["cleanup_cancel_sent"] = True
                response = auth.read_frame(process, 2)
                if auth.HEADER.unpack_from(response)[1] == 9:
                    plain = decrypt_frame(response, keys[0])
                    result["cleanup_response"] = summarize_control(plain)
                    result["cleanup_cancel_acknowledged"] = tlvs(plain) == [(1, auth.tlv(3, b"senderCancelACK"))]
            except (OSError, ValueError):
                result["cleanup_cancel_acknowledged"] = False
        for channel in channels:
            if channel.poll() is None:
                channel.terminate()
            try:
                channel.wait(timeout=2)
            except subprocess.TimeoutExpired:
                channel.kill()
                channel.wait()
            try:
                channel.stdin.close()
            except BrokenPipeError:
                pass
            channel.stdout.close()
        if process.poll() is None:
            process.terminate()
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
        try:
            process.stdin.close()
        except BrokenPipeError:
            pass
        process.stdout.close()
        keys.clear()
        save()


if __name__ == "__main__":
    main()
