#!/usr/bin/env python3
"""Bounded synthetic Huawei offer, followed by cancellation; no file transport.

Uses the production offer serializer. Requires an explicit currently verified
LAN endpoint. Does not persist keys, send file bytes, or accept phone UI prompts.
"""
import argparse
import importlib.util
import ipaddress
import json
from pathlib import Path
import struct
import subprocess
import time


def investigate(peer_ip, port, kind, seconds=4):
    from cryptography.hazmat.primitives.asymmetric import rsa
    from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
    path = Path(__file__).resolve().parents[1] / 'huawei-transfer-probe.py'
    spec = importlib.util.spec_from_file_location('classification_transfer', path)
    transfer = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(transfer)
    auth = transfer.auth
    if not auth.private_ipv4(peer_ip) or not 1 <= port <= 65535 or not 1 <= seconds <= 10:
        raise ValueError('invalid endpoint or bounded duration')
    source = next((x for x in auth.interfaces() if x.interface == 'en0'
                   and ipaddress.ip_address(peer_ip) in x.network), None)
    route = subprocess.run(['/sbin/route', '-n', 'get', peer_ip], capture_output=True, text=True, timeout=3)
    if source is None or source.address == peer_ip or not any(
            line.strip() == 'interface: en0' for line in route.stdout.splitlines()):
        raise ValueError('endpoint is not another device on the current en0 LAN')
    names = {'photo': ['androp-offer-check.jpg'],
             'video': ['androp-offer-check.mp4'],
             'mixed': ['androp-offer-check.jpg', 'androp-offer-check.mp4']}[kind]
    offer = transfer.offer(names[0], 1234 * len(names), len(names),
                           'anDrop icon check', filenames=names)
    fields = dict(transfer.tlvs(auth.unwrap_tlv(offer, 7)))
    result = {'kind': kind, 'send_type': int(fields[1]), 'file_count': len(names),
              'file_data_sent': False, 'responses': [], 'stage': 'opening'}
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    public = key.public_key().public_bytes(Encoding.DER, PublicFormat.SubjectPublicKeyInfo)
    digest = auth.key_hash(public)
    device = digest[:8].hex().upper().encode()
    identity = ''.join(f'{word:04X}' for word in struct.unpack('<HHH', digest[:6]))
    # Keep nc alive through the bounded observation and cancellation windows.
    process = subprocess.Popen(['/usr/bin/nc', '-G', '3', '-w', str(seconds + 12), peer_ip, str(port)],
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    keys = []

    def send(packet):
        process.stdin.write(packet)
        process.stdin.flush()

    try:
        send(auth.opening(identity))
        opening = auth.summarize(auth.read_frame(process, 4))
        if opening.get('code') != 4 or opening['module'] != 8 or opening['flags'] != 1:
            raise ValueError('opening not acknowledged')
        result['stage'] = 'capabilities'
        send(auth.capabilities(device))
        capability = auth.read_frame(process, 4)
        mode, body = auth.unpack_envelope(capability)
        if mode != 0 or not any(tag == 3 for tag, _ in transfer.tlvs(body)):
            raise ValueError('capabilities not acknowledged')
        result['stage'] = 'authentication'
        send(auth.envelope_frame(device, auth.tlv(6, auth.tlv(1, public)), 3))
        auth.challenge(process, device, auth.read_frame(process, 8), capability, key, keys.append)
        result['authentication_complete'] = True
        send(transfer.encrypted_frame(device, keys[0], offer, 5))
        result['offer_sent'] = True
        result['stage'] = 'offer_wait'
        deadline = time.monotonic() + seconds
        for _ in range(8):
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            raw = auth.read_frame(process, remaining)
            if auth.HEADER.unpack_from(raw)[1] == 9:
                control = transfer.decrypt_frame(raw, keys[0])
                result['responses'].append(transfer.summarize_control(control))
                commands = transfer.tlvs(control)
                if any(
                        value == b'user_reject' for tag, data in commands if tag == 1
                        for _, value in transfer.tlvs(data)):
                    result['receiver_rejected'] = True
                    break
                if commands == [(1, auth.tlv(1, b'user_confirm'))]:
                    result['receiver_accepted'] = True
                    break
            else:
                # Do not negotiate any requested file/byte transport.
                result['channel_request_received'] = True
                break
    except (ValueError, OSError) as error:
        # Avoid echoing data from the receiver or OS errors containing addresses.
        result['stop_type'] = type(error).__name__
        if str(error) == 'incomplete frame or response deadline':
            result['stop_reason'] = 'incomplete_frame_or_deadline'
        elif str(error) == 'invalid frame header':
            result['stop_reason'] = 'invalid_frame_header'
    finally:
        if keys and result.get('offer_sent') and not result.get('receiver_rejected'):
            transfer.cancel_receive(process, device, keys[0], result, lambda: None)
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
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--peer-ip', required=True)
    parser.add_argument('--port', type=int, required=True)
    parser.add_argument('--kind', choices=('photo', 'video', 'mixed'), required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    result = investigate(args.peer_ip, args.port, args.kind)
    rendered = json.dumps(result, indent=2) + '\n'
    args.output.write_text(rendered)
    print(rendered, end='')


if __name__ == '__main__':
    main()
