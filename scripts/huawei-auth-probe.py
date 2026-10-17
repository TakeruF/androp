#!/usr/bin/env python3
"""Bounded Huawei WLAN auth-channel opening experiment, not full authentication.

Uses synthetic ephemeral identities. No account credentials, file transfer,
hotspot, pairing persistence, or Petal runtime/library dependency.
"""

import argparse
import hashlib
import hmac
import ipaddress
import json
import os
from pathlib import Path
import platform
import secrets
import select
import struct
import subprocess
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Sources"))
from network_routes import interfaces, private_ipv4

HEADER = struct.Struct("<IIQII")
MAGIC = 0xBABEFACE
LIMIT = 65536


def frame(module, sequence, payload):
    return HEADER.pack(MAGIC, module, sequence, 0, len(payload)) + payload


def opening(identity):
    fields = {
        "CODE": 4, "DEVICE_ID": identity, "PEER_NETWORK_ID": identity,
        "PKG_NAME": "ohos.InterConnection.iShare",
        "SRC_BUS_NAME": "IShareEcologyAuthSession",
        "DST_BUS_NAME": "IShareEcologyAuthSession", "REQ_ID": "0",
        "API_VERSION": 2, "MTU_SIZE": 39968, "ROUTE_TYPE": 2,
    }
    return frame(8, 1, json.dumps(fields, separators=(",", ":")).encode() + b"\0")


def varint(value):
    """Seven-bit groups, with MSB marking the final byte (not protobuf)."""
    if not 0 <= value < 1 << 28:
        raise ValueError("varint outside research format")
    result = bytearray()
    while value >= 128:
        result.append(value & 127)
        value >>= 7
    result.append(value | 128)
    return bytes(result)


def read_varint(data, offset):
    value = 0
    for shift in range(0, 28, 7):
        if offset >= len(data):
            raise ValueError("truncated varint")
        byte = data[offset]
        offset += 1
        value |= (byte & 127) << shift
        if byte & 128:
            return value, offset
    raise ValueError("oversized varint")


def tlv(tag, value):
    return varint(tag) + varint(len(value)) + value


def capabilities(device_hash):
    fields = (tlv(1, b"1") + tlv(2, b"1.0.0")
              + tlv(3, platform.mac_ver()[0].encode())
              + tlv(4, platform.machine().encode()))
    payload = tlv(2, fields)
    return envelope_frame(device_hash, payload, 2)


def envelope_frame(device_hash, payload, sequence):
    envelope = device_hash + b"\x81\xe5\x80\x80" + varint(len(payload)) + payload
    return frame(9, sequence, envelope)


def key_hash(public_der):
    return hmac.new(public_der[:16], public_der, hashlib.sha256).digest()


def protocol_v2_identity(public_der):
    """HarmonyOS ProtocolV2: six HMAC bytes in byte order, not uint16 order."""
    return key_hash(public_der)[:6].hex().upper()


def meta_node_id(public_der):
    """Stable 64-hex MetaNode ID derived from this Mac's own public key only."""
    return hmac.new(public_der[:16], b'anDrop META_NODE_ID\0' + public_der, hashlib.sha256).hexdigest().upper()


def load_identity_key(path):
    """Load or create this Mac's RSA-2048 share identity (owner-only PEM).

    It names the Mac to phones across runs. It is not a peer credential and
    never authenticates the phone.
    """
    from cryptography.hazmat.primitives.asymmetric import rsa
    from cryptography.hazmat.primitives.serialization import (Encoding, NoEncryption, PrivateFormat,
                                                              load_pem_private_key)
    path = Path(path)
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    except FileNotFoundError:
        key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        data = key.private_bytes(Encoding.PEM, PrivateFormat.PKCS8, NoEncryption())
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        # Publish complete PEM only: a concurrent reader never sees a partial key.
        partial = path.with_name(f'.{path.name}.{secrets.token_hex(8)}')
        try:
            with os.fdopen(os.open(partial, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600), 'wb') as output:
                output.write(data)
                output.flush()
                os.fsync(output.fileno())
            os.link(partial, path)  # Fails if another process created it first.
            return key
        except FileExistsError:
            pass
        finally:
            partial.unlink(missing_ok=True)
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(descriptor, 'rb') as source:
        info = os.fstat(source.fileno())
        if not (info.st_mode & 0o170000 == 0o100000 and info.st_uid == os.getuid() and not info.st_mode & 0o077
                and info.st_size <= 8192):
            raise ValueError('identity key must be a small owner-only regular file')
        key = load_pem_private_key(source.read(), password=None)
    if not isinstance(key, rsa.RSAPrivateKey) or key.key_size != 2048:
        raise ValueError('identity key must be RSA-2048')
    return key


def unpack_envelope(data):
    if HEADER.unpack(data[:HEADER.size])[1] != 9:
        raise ValueError("not an application frame")
    payload = data[HEADER.size:]
    values, offset = [], 16
    for _ in range(4):
        value, offset = read_varint(payload, offset)
        values.append(value)
    if values[:2] != [1, 101]:
        raise ValueError("unsupported envelope")
    offset += values[3]
    size, offset = read_varint(payload, offset)
    if offset + size != len(payload):
        raise ValueError("invalid envelope length")
    return values[2], payload[offset:]


def unwrap_tlv(data, expected_tag):
    tag, offset = read_varint(data, 0)
    size, offset = read_varint(data, offset)
    if tag != expected_tag or offset + size != len(data):
        raise ValueError("unexpected TLV")
    return data[offset:]


def challenge(process, device_hash, peer_response, capability_response, ephemeral_key, on_session_key=None):
    """Verify an ephemeral RSA/AES exchange; this does not authenticate identity."""
    from cryptography.hazmat.primitives import hashes
    from cryptography.hazmat.primitives.asymmetric import padding, rsa
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    from cryptography.hazmat.primitives.serialization import load_der_public_key
    mode, body = unpack_envelope(peer_response)
    if mode != 0:
        raise ValueError("expected plaintext public key")
    peer_key = load_der_public_key(unwrap_tlv(unwrap_tlv(body, 6), 2))
    if not isinstance(peer_key, rsa.RSAPublicKey) or peer_key.key_size != 2048:
        raise ValueError("unexpected public key type")
    mode, body = unpack_envelope(capability_response)
    fields = unwrap_tlv(body, 3)
    tag, offset = read_varint(fields, 0)
    size, offset = read_varint(fields, offset)
    version_text = fields[offset:offset + size]
    if mode != 0 or tag != 1 or not 0 <= size <= 10 or (size and not version_text.isdigit()) or len(version_text) != size:
        raise ValueError("unsupported secure version")
    secure_version = int(version_text or b"0") & 1
    # The negotiated bit selects MGF1; OAEP always uses SHA-256.
    oaep = padding.OAEP(mgf=padding.MGF1(hashes.SHA1() if secure_version else hashes.SHA256()), algorithm=hashes.SHA256(), label=None)
    nonce, key = secrets.token_bytes(16), secrets.token_bytes(32)
    plaintext = tlv(6, tlv(3, nonce + key))
    ciphertext = peer_key.encrypt(plaintext, oaep)
    metadata = tlv(1, secrets.token_bytes(8))
    envelope = (device_hash + b"\x81\xe5\x83" + varint(len(metadata)) + metadata
                + varint(len(ciphertext)) + ciphertext)
    process.stdin.write(frame(9, 4, envelope))
    process.stdin.flush()
    response = read_frame(process)
    mode, ciphertext = unpack_envelope(response)
    if mode != 3:
        raise ValueError("expected RSA response")
    plaintext = ephemeral_key.decrypt(ciphertext, oaep)
    encrypted_session_key = unwrap_tlv(unwrap_tlv(plaintext, 6), 4)
    from cryptography.exceptions import InvalidTag
    try:
        session_key = AESGCM(key).decrypt(nonce, encrypted_session_key, None)
    except InvalidTag:
        raise ValueError("session key integrity verification failed") from None
    if len(session_key) != 32:
        raise ValueError("unexpected session key size")
    if on_session_key is not None:
        on_session_key(session_key)
    # Neither this session key nor private/public keys are saved or printed.
    return {"secure_version_bit": secure_version, "rsa_response_decrypted": True, "aes_gcm_tag_verified": True,
            "session_key_bytes": len(session_key), "peer_identity_authenticated": False}


def read_frame(process, seconds=4):
    data = bytearray()
    deadline = time.monotonic() + seconds
    expected = HEADER.size
    while len(data) < expected and time.monotonic() < deadline:
        ready, _, _ = select.select([process.stdout], [], [], max(0, deadline - time.monotonic()))
        if not ready:
            break
        chunk = os.read(process.stdout.fileno(), expected - len(data))
        if not chunk:
            break
        data.extend(chunk)
        if len(data) == HEADER.size:
            magic, _, _, _, length = HEADER.unpack(data)
            if magic != MAGIC or length > LIMIT:
                raise ValueError("invalid frame header")
            expected += length
    if len(data) != expected:
        raise ValueError("incomplete frame or response deadline")
    return bytes(data)


def summarize(data):
    magic, module, sequence, flags, length = HEADER.unpack(data[:HEADER.size])
    result = {"bytes": len(data), "magic_matches": magic == MAGIC,
              "module": module, "flags": flags, "payload_bytes": length}
    payload = data[HEADER.size:]
    if module == 8:
        value = json.loads(payload.rstrip(b"\0"))
        result["known_fields"] = sorted(set(value) & {
            "CODE", "API_VERSION", "MTU_SIZE", "ROUTE_TYPE", "ERR_CODE",
            "SRC_BUS_NAME", "DST_BUS_NAME", "PKG_NAME", "DEVICE_ID", "PEER_NETWORK_ID",
        })
        for key in ("CODE", "API_VERSION", "MTU_SIZE", "ROUTE_TYPE", "ERR_CODE"):
            if type(value.get(key)) is int:
                result[key.lower()] = value[key]
    elif module == 9 and len(payload) >= 16:
        offset = 16  # Peer hash is deliberately omitted from output.
        values = []
        for _ in range(4):
            value, offset = read_varint(payload, offset)
            values.append(value)
        result["envelope"] = dict(zip(("version", "protocol", "security_mode", "security_metadata_bytes"), values))
        offset += values[3]
        size, offset = read_varint(payload, offset)
        if offset + size != len(payload):
            raise ValueError("invalid envelope length")
        if values[2] == 0:
            end = offset + size
            tags = []
            while offset < end and len(tags) < 16:
                tag, offset = read_varint(payload, offset)
                size, offset = read_varint(payload, offset)
                if offset + size > end:
                    raise ValueError("invalid TLV length")
                item = {"tag": tag, "bytes": size}
                if tag == 6 and size:
                    subtype, inner = read_varint(payload, offset)
                    key_size, inner = read_varint(payload, inner)
                    item.update(subtype=subtype, inner_bytes=key_size)
                    if subtype == 2 and inner + key_size == offset + size:
                        from cryptography.hazmat.primitives.serialization import load_der_public_key
                        public_der = payload[inner:inner + key_size]
                        public_key = load_der_public_key(public_der)
                        item["public_key_bits"] = public_key.key_size
                        item["hash_matches_envelope"] = key_hash(public_der)[:8].hex().upper().encode() == payload[:16].upper()
                tags.append(item)
                offset += size
            result["plaintext_tlvs"] = tags
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--peer-ip", required=True)
    parser.add_argument("--port", required=True, type=int, help="port just advertised by the test phone")
    parser.add_argument("--interface", default="en0")
    parser.add_argument("--capabilities", action="store_true", help="after opening response: one synthetic capability negotiation request")
    parser.add_argument("--public-key", action="store_true", help="with --capabilities: exchange an ephemeral RSA public key; requires cryptography; does not establish trust")
    parser.add_argument("--key-challenge", action="store_true", help="with --public-key: verify an ephemeral RSA/AES challenge; no files or persistent trust")
    args = parser.parse_args()
    if args.public_key and not args.capabilities:
        parser.error("--public-key requires --capabilities")
    if args.key_challenge and not args.public_key:
        parser.error("--key-challenge requires --public-key")
    if sys.platform != "darwin" or not private_ipv4(args.peer_ip) or not 1 <= args.port <= 65535:
        parser.error("Use macOS, a private test-device IP and an advertised port")
    source = next((x for x in interfaces() if x.interface == args.interface and ipaddress.ip_address(args.peer_ip) in x.network), None)
    if source is None or args.peer_ip == source.address:
        parser.error("Peer must be another device on the selected active LAN subnet")
    route = subprocess.run(["/sbin/route", "-n", "get", args.peer_ip], capture_output=True, text=True, timeout=3)
    if not any(line.strip() == f"interface: {args.interface}" for line in route.stdout.splitlines()):
        parser.error("Current route does not use the selected LAN interface")
    # Synthetic identifiers are not represented as authenticated key hashes.
    device_hash = secrets.token_hex(8).upper().encode()
    identity = device_hash[:12].decode()
    public_der = None
    if args.public_key:
        from cryptography.hazmat.primitives.asymmetric import rsa
        from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
        ephemeral_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        public_der = ephemeral_key.public_key().public_bytes(Encoding.DER, PublicFormat.SubjectPublicKeyInfo)
        digest = key_hash(public_der)
        device_hash = digest[:8].hex().upper().encode()
        identity = "".join(f"{word:04X}" for word in struct.unpack("<HHH", digest[:6]))
    result = {"authentication_complete": False, "transfer_attempted": False, "responses": []}
    process = subprocess.Popen(
        ["/usr/bin/nc", "-G", "3", "-w", "6", args.peer_ip, str(args.port)],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
    )
    try:
        process.stdin.write(opening(identity))
        process.stdin.flush()  # Keep stdin open: EOF can discard the async reply.
        response = summarize(read_frame(process))
        result["responses"].append(response)
        if args.capabilities and response["module"] == 8 and response.get("code") == 4 and response["flags"] == 1:
            process.stdin.write(capabilities(device_hash))
            process.stdin.flush()
            result["capability_request_sent"] = True
            capability_raw = read_frame(process)
            capability_response = summarize(capability_raw)
            result["responses"].append(capability_response)
            if public_der and any(t.get("tag") == 3 for t in capability_response.get("plaintext_tlvs", [])):
                process.stdin.write(envelope_frame(device_hash, tlv(6, tlv(1, public_der)), 3))
                process.stdin.flush()
                result["public_key_request_sent"] = True
                public_key_raw = read_frame(process)
                result["responses"].append(summarize(public_key_raw))
                if args.key_challenge:
                    result["key_challenge_requested"] = True
                    result["key_challenge"] = challenge(process, device_hash, public_key_raw, capability_raw, ephemeral_key)
        result["status"] = "response_received"
    except (OSError, ValueError) as error:
        result.update(status="incomplete", error_type=type(error).__name__)
        if type(error) is ValueError:
            result["error_reason"] = str(error)
    finally:
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
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
