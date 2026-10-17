#!/usr/bin/env python3
"""Receive handshake; inspect/reject by default, optional bounded fixture callback."""
import importlib.util
import json
from pathlib import Path
import secrets
import time

spec = importlib.util.spec_from_file_location('huawei_transfer', Path(__file__).with_name('huawei-transfer-probe.py'))
transfer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(transfer)
auth = transfer.auth


def inspect_offer(process, opening, result, save, private=None, receive=None, expected_size=77, expected_count=1, accept_bounded_files=False, approve=None, identify=None):
    from cryptography.hazmat.primitives.asymmetric import rsa, padding
    from cryptography.hazmat.primitives import hashes
    from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat, load_der_public_key
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    def send(packet):
        process.stdin.write(packet)
        process.stdin.flush()
    deadline = time.monotonic() + 24
    def read():
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise ValueError("receive handshake deadline")
        packet = auth.read_frame(process, min(8, remaining))
        summary = auth.summarize(packet)
        summary['sequence'] = auth.HEADER.unpack_from(packet)[2]
        result.setdefault('receive_frames', []).append(summary)
        save()
        return packet
    header = auth.HEADER.unpack_from(opening)
    value = json.loads(opening[24:].rstrip(b'\0'))
    if header[1] != 8 or value.get('CODE') != 4 or value.get('DST_BUS_NAME') != 'IShareEcologyAuthSession':
        raise ValueError('unsupported receive session')
    private = private or rsa.generate_private_key(public_exponent=65537, key_size=2048)
    public = private.public_key().public_bytes(Encoding.DER, PublicFormat.SubjectPublicKeyInfo)
    device_hash = auth.key_hash(public)[:8].hex().upper().encode()
    identity = auth.protocol_v2_identity(public)
    # Petal's ACK formatter uses lowercase hex (C++ std::hex, no uppercase).
    reply = json.dumps({'CODE': 4, 'DEVICE_ID': identity.lower(), 'PEER_NETWORK_ID': identity.lower(), 'API_VERSION': 2,
                        'PKG_NAME': 'ohos.InterConnection.iShare', 'SRC_BUS_NAME': 'IShareEcologyAuthSession',
                        'DST_BUS_NAME': 'IShareEcologyAuthSession', 'REQ_ID': '0',
                        'MTU_SIZE': 39968, 'ROUTE_TYPE': 2}, separators=(',', ':')).encode() + b'\0'
    send(auth.HEADER.pack(auth.MAGIC, 8, 0, 1, len(reply)) + reply)
    result['opening_ack_sent'] = True
    result['experimental_petal_opening_ack'] = True
    capability_packet = read()
    mode, body = auth.unpack_envelope(capability_packet)
    if mode != 0:
        raise ValueError('expected plaintext capability request')
    auth.unwrap_tlv(body, 2)
    send(auth.envelope_frame(device_hash, auth.tlv(3, auth.tlv(1, b'')), 0))
    result['capabilities_replied'] = True
    public_packet = read()
    mode, body = auth.unpack_envelope(public_packet)
    if mode != 0:
        raise ValueError('expected public key request')
    peer_der = auth.unwrap_tlv(auth.unwrap_tlv(body, 6), 1)
    peer_public = load_der_public_key(peer_der)
    if not isinstance(peer_public, rsa.RSAPublicKey) or peer_public.key_size != 2048:
        raise ValueError('unsupported peer public key')
    # Compare in memory only: no peer identifiers or public key bytes in evidence.
    peer_digest = auth.key_hash(peer_der)
    result['peer_hash_diagnostics'] = {
        'envelope_consistent': capability_packet[24:40] == public_packet[24:40],
        'petal_key_hash_matches_envelope': peer_digest[:8].hex().upper().encode() == public_packet[24:40].upper(),
        'opening_identity_bytes': len(str(value.get('DEVICE_ID', '')).encode()),
    }
    send(auth.envelope_frame(device_hash, auth.tlv(6, auth.tlv(2, public)), 0))
    result['public_key_replied'] = True
    save()
    mode, ciphertext = auth.unpack_envelope(read())
    if mode != 3:
        raise ValueError('expected RSA challenge')
    oaep = padding.OAEP(mgf=padding.MGF1(hashes.SHA256()), algorithm=hashes.SHA256(), label=None)
    challenge = auth.unwrap_tlv(auth.unwrap_tlv(private.decrypt(ciphertext, oaep), 6), 3)
    if len(challenge) != 48:
        raise ValueError('invalid challenge length')
    session_key = secrets.token_bytes(32)
    encrypted = AESGCM(challenge[16:]).encrypt(challenge[:16], session_key, None)
    ciphertext = peer_public.encrypt(auth.tlv(6, auth.tlv(4, encrypted)), oaep)
    metadata = auth.tlv(1, secrets.token_bytes(8))
    envelope = device_hash + b'\x81\xe5\x83' + auth.varint(len(metadata)) + metadata + auth.varint(len(ciphertext)) + ciphertext
    send(auth.frame(9, 0, envelope))
    result['session_key_sent'] = True
    plain = transfer.decrypt_frame(read(), session_key)
    pairs = transfer.tlvs(auth.unwrap_tlv(plain, 7))
    fields = dict(pairs)
    if len(fields) != len(pairs):
        raise ValueError('duplicate offer field')
    result['ephemeral_key_exchange_complete'] = True
    result['offer_integrity_verified'] = True
    result['offer_field_lengths'] = {str(k): len(v) for k, v in fields.items()}
    result['matches_synthetic_size_and_count'] = fields.get(4) == b'77' and fields.get(3) == b'1'
    result['expected_synthetic_offer'] = (fields.get(7) == b'androp-huawei-probe-20261017.txt'
                                         and fields.get(4) == b'77' and fields.get(3) == b'1')
    result['peer_identity_authenticated'] = False
    # A valid offer proves possession of the RSA key that received our random
    # session key. Expose its canonical public key only to the runtime callback;
    # never put peer keys/identifiers in probe evidence. This is continuity for
    # local enrollment, not vendor/account authentication of a new device.
    if identify is not None:
        identify(peer_public.public_bytes(Encoding.DER, PublicFormat.SubjectPublicKeyInfo))
    result['matches_expected_fixture_size_and_count'] = fields.get(4) == str(expected_size).encode() and fields.get(3) == str(expected_count).encode()
    bounded = False
    if accept_bounded_files:
        count, size = fields.get(3, b''), fields.get(4, b'')
        if count.isdigit() and size.isdigit() and len(count) <= 2 and len(size) <= 8:
            count, size = int(count), int(size)
            bounded = 1 <= count <= 16 and 0 <= size <= 16 * 1024 * 1024
            if bounded:
                result.update(accepted_file_count=count, accepted_total_bytes=size, bounded_offer_accepted=True)
    accepted_offer = bounded if accept_bounded_files else result['matches_expected_fixture_size_and_count']
    if receive is not None and accepted_offer and (approve is None or approve()):
        # Explicit reference or bounded batch mode; validate DFile metadata before save.
        try:
            receive(device_hash, session_key)
        finally:
            if not result.get('dfile_done_ack_verified') and not result.get('receiver_cancel_attempted'):
                transfer.cancel_receive(process, device_hash, session_key, result, save)
        return
    # Inspection phase does not accept file data. This is explicit in the log.
    send(transfer.encrypted_frame(device_hash, session_key, auth.tlv(1, auth.tlv(1, b'user_reject')), 5))
    result['inspection_offer_rejected'] = True
    save()
