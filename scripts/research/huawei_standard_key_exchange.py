#!/usr/bin/env python3
"""Bounded standard-route key exchange; never offers or transfers a file.

Independent research tool, not part of anDrop. Defaults to a fresh RSA key;
optionally reads this Mac's existing anDrop identity without modifying it.
Makes no account/contact claims and does not import vendor certificates.
The returned transport key is not proof of sharing permission: verify mode 0
is a refusal, and modes 1/2 require further certificate/HiChain verification.
Only structural results are returned; keys and peer identifiers stay in RAM.
"""
import argparse
import importlib.util
import ipaddress
import json
import os
from pathlib import Path
import secrets
import stat
import subprocess
import sys

spec = importlib.util.spec_from_file_location(
    'standard_exchange_auth', Path(__file__).resolve().parents[1] / 'huawei-auth-probe.py')
auth = importlib.util.module_from_spec(spec)
spec.loader.exec_module(auth)


def fields(data):
    result, offset = [], 0
    while offset < len(data):
        tag, offset = auth.read_varint(data, offset)
        size, offset = auth.read_varint(data, offset)
        if len(result) >= 32 or size > len(data) - offset:
            raise ValueError('invalid field count or length')
        result.append((tag, data[offset:offset + size]))
        offset += size
    return result


def envelope(device, body, sequence, protocol=100, mode=0, metadata=b''):
    if len(device) != 16 or protocol not in (0, 100) or mode not in (0, 3):
        raise ValueError('unsupported research envelope')
    return auth.frame(9, sequence, device + b''.join(auth.varint(x) for x in (
        1, protocol, mode, len(metadata))) + metadata + auth.varint(len(body)) + body)


def parse_envelope(raw):
    if len(raw) < auth.HEADER.size + 21:
        raise ValueError('short envelope')
    magic, module, _, _, length = auth.HEADER.unpack_from(raw)
    if magic != auth.MAGIC or module != 9 or length != len(raw) - auth.HEADER.size:
        raise ValueError('invalid frame header')
    offset, values = auth.HEADER.size + 16, []
    for _ in range(4):
        value, offset = auth.read_varint(raw, offset)
        values.append(value)
    version, protocol, mode, metadata_size = values
    if version != 1 or protocol not in (0, 100) or mode not in (0, 3):
        raise ValueError('unexpected protocol or security mode')
    if metadata_size > 64 or metadata_size > len(raw) - offset:
        raise ValueError('invalid metadata length')
    offset += metadata_size
    size, offset = auth.read_varint(raw, offset)
    if offset + size != len(raw) or size > 4096:
        raise ValueError('invalid payload length')
    return protocol, mode, raw[offset:]


def key_response(body, temporary_key, nonce):
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    values = fields(body)
    if len(values) != 2 or {tag for tag, _ in values} != {19, 23}:
        raise ValueError('unexpected key response fields')
    values = dict(values)
    if values[23] not in (b'0', b'1', b'2', b'3') or len(values[19]) != 48:
        raise ValueError('unexpected verify mode or wrapped key length')
    session_key = AESGCM(temporary_key).decrypt(nonce, values[19], None)
    if len(session_key) != 32:
        raise ValueError('unexpected session key size')
    # Deliberately discard the transport key. This tool cannot continue with
    # an offer, including when key exchange succeeds but sharing is refused.
    return {'session_key_challenge_verified': True, 'verify_mode': int(values[23]),
            'sharing_refused': values[23] == b'0',
            'further_verification_required': values[23] in (b'1', b'2'),
            'contact_mismatch': values[23] == b'3',
            'sharing_authorized': False}


def validate_endpoint(peer_ip, port):
    if sys.platform != 'darwin' or not auth.private_ipv4(peer_ip) or not 1 <= port <= 65535:
        raise ValueError('requires macOS and a private LAN endpoint')
    source = next((x for x in auth.interfaces() if x.interface == 'en0'
                   and ipaddress.ip_address(peer_ip) in x.network), None)
    route = subprocess.run(['/sbin/route', '-n', 'get', peer_ip],
                           capture_output=True, text=True, timeout=3)
    if source is None or source.address == peer_ip or not any(
            x.strip() == 'interface: en0' for x in route.stdout.splitlines()):
        raise ValueError('endpoint must be another device on the current en0 LAN')


def read_existing_identity(path):
    """Read an owner-only RSA identity without creating or replacing anything."""
    from cryptography.hazmat.primitives.asymmetric import rsa
    from cryptography.hazmat.primitives.serialization import load_pem_private_key
    with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK), 'rb') as source:
        info = os.fstat(source.fileno())
        if not (stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid()
                and not info.st_mode & 0o077 and info.st_size <= 8192):
            raise ValueError('identity must be a small owner-only regular file')
        data = source.read(8193)
        if len(data) > 8192:
            raise ValueError('identity exceeds size limit')
        key = load_pem_private_key(data, password=None)
    if not isinstance(key, rsa.RSAPrivateKey) or key.key_size != 2048:
        raise ValueError('identity must be RSA-2048')
    return key


def probe(peer_ip, port, identity_key=None, send_node_id=False):
    from cryptography.exceptions import InvalidTag
    from cryptography.hazmat.primitives import hashes
    from cryptography.hazmat.primitives.asymmetric import padding, rsa
    from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat, load_der_public_key
    validate_endpoint(peer_ip, port)
    if send_node_id and identity_key is None:
        raise ValueError('node identity comparison requires the existing local anDrop key')
    if identity_key is None:
        key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    else:
        key = read_existing_identity(identity_key)
    public = key.public_key().public_bytes(Encoding.DER, PublicFormat.SubjectPublicKeyInfo)
    device = (auth.key_hash(public)[:8].hex().upper().encode('ascii') if identity_key else
              secrets.token_hex(8).upper().encode('ascii'))
    oaep = padding.OAEP(mgf=padding.MGF1(hashes.SHA256()), algorithm=hashes.SHA256(), label=None)
    result = {'file_offer_sent': False, 'file_data_sent': False,
              'local_identity': 'existing_anDrop_key' if identity_key else 'ephemeral',
              'local_node_id_sent': send_node_id,
              'peer_identity_authenticated': False, 'sharing_authorized': False,
              'live_icon_verified': False, 'responses': [], 'stage': 'opening'}
    process = subprocess.Popen(['/usr/bin/nc', '-G', '3', '-w', '8', peer_ip, str(port)],
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)

    def send(packet):
        process.stdin.write(packet)
        process.stdin.flush()

    def command(items, sequence):
        send(envelope(device, auth.tlv(192, b''.join(auth.tlv(k, v) for k, v in items)), sequence))

    def receive(protocol, mode, expected_tags, command_body=False):
        actual_protocol, actual_mode, body = parse_envelope(auth.read_frame(process, 4))
        if (actual_protocol, actual_mode) != (protocol, mode):
            raise ValueError('unexpected response envelope')
        if mode == 3:
            body = key.decrypt(body, oaep)
        if command_body:
            body = auth.unwrap_tlv(body, 192)
        items = fields(body)
        if len(items) != len(expected_tags) or {k for k, _ in items} != set(expected_tags):
            raise ValueError('unexpected response fields')
        result['responses'].append({'protocol': protocol, 'mode': mode,
                                    'fields': [{'tag': k, 'bytes': len(v)} for k, v in items]})
        return body, dict(items)

    try:
        opening = json.loads(auth.opening(device[:12].decode())[auth.HEADER.size:].rstrip(b'\0'))
        opening['SRC_BUS_NAME'] = opening['DST_BUS_NAME'] = 'IShareAuthSession'
        send(auth.frame(8, 1, json.dumps(opening, separators=(',', ':')).encode() + b'\0'))
        response = auth.summarize(auth.read_frame(process, 4))
        if (response.get('module'), response.get('flags'), response.get('code')) != (8, 1, 4):
            raise ValueError('opening not acknowledged')
        result['stage'] = 'capabilities'
        command([(234, b'0'), (215, b'0'), (213, b'1'), (211, b'31')], 2)
        receive(100, 0, (234,), True)
        receive(100, 0, (212,), True)
        result['stage'] = 'public_key_request'
        command([(217, public)], 3)
        _, items = receive(100, 0, (218,), True)
        if not isinstance(load_der_public_key(items[218]), rsa.RSAPublicKey):
            raise ValueError('unexpected public key type')
        result['stage'] = 'auth_send_type'
        command([(193, b'3')], 4)
        _, items = receive(100, 0, (224, 195), True)
        if items[195] != b'CMD_CAN_CONTINUE_CONNECT':
            raise ValueError('receiver did not permit key exchange')
        result['stage'] = 'ccmp_public_key'
        send(envelope(device, auth.tlv(16, public), 5, protocol=0))
        _, items = receive(0, 0, (17,))
        peer_key = load_der_public_key(items[17])
        if not isinstance(peer_key, rsa.RSAPublicKey) or peer_key.key_size != 2048:
            raise ValueError('unexpected RSA key')
        nonce, temporary_key = secrets.token_bytes(16), secrets.token_bytes(32)
        key_request = auth.tlv(18, nonce + temporary_key)
        if send_node_id:
            key_request = auth.tlv(22, auth.meta_node_id(public).encode('ascii')) + key_request
        ciphertext = peer_key.encrypt(key_request, oaep)
        result['stage'] = 'ccmp_key_challenge'
        send(envelope(device, ciphertext, 6, protocol=0, mode=3,
                      metadata=auth.tlv(1, secrets.token_bytes(8))))
        body, _ = receive(0, 3, (24, 23, 19) if send_node_id else (23, 19))
        if send_node_id:
            body = b''.join(auth.tlv(k, v) for k, v in fields(body) if k != 24)
        result.update(key_response(body, temporary_key, nonce))
        result['stage'] = 'sharing_refused' if result['sharing_refused'] else 'key_exchange_only'
    except (ValueError, OSError, InvalidTag) as error:
        result['stop_type'] = type(error).__name__
    finally:
        if process.poll() is None:
            process.terminate()
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=2)
        try:
            process.stdin.close()
        except BrokenPipeError:
            pass
        process.stdout.close()
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--peer-ip', required=True)
    parser.add_argument('--port', required=True, type=int)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--identity-key', type=Path, help='read-only use of this Mac\'s existing anDrop key')
    parser.add_argument('--send-node-id', action='store_true', help='include this Mac\'s key-derived MetaNode ID')
    args = parser.parse_args()
    result = probe(args.peer_ip, args.port, args.identity_key, args.send_node_id)
    rendered = json.dumps(result, indent=2) + '\n'
    args.output.write_text(rendered)
    print(rendered, end='')


if __name__ == '__main__':
    main()
