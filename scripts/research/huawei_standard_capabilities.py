#!/usr/bin/env python3
"""Bounded, metadata-only investigation of Huawei Share's standard LAN route.

Opens IShareAuthSession and asks for capabilities using module 100/command 192.
No preview, filename, file bytes, key exchange, account identity, or persistent
pairing is sent. A response proves capability negotiation, not authentication
or thumbnail rendering. This script is not part of the installed app.
"""
import argparse
import importlib.util
import ipaddress
import json
from pathlib import Path
import secrets
import subprocess
import sys

spec = importlib.util.spec_from_file_location(
    'huawei_auth_probe', Path(__file__).resolve().parents[1] / 'huawei-auth-probe.py')
auth = importlib.util.module_from_spec(spec)
spec.loader.exec_module(auth)


def capability_packet(device_hash):
    fields = b''.join(auth.tlv(tag, value) for tag, value in (
        (234, b'0'), (215, b'0'), (213, b'1'), (211, b'31')))
    payload = auth.tlv(192, fields)
    envelope = device_hash + b''.join(auth.varint(value) for value in (
        1, 100, 0, 0, len(payload))) + payload
    return auth.frame(9, 2, envelope)


def summarize_response(raw):
    summary = auth.summarize(raw)
    expected = {'version': 1, 'protocol': 100, 'security_mode': 0, 'security_metadata_bytes': 0}
    if summary.get('envelope') != expected:
        raise ValueError('unexpected standard-route envelope')
    offset = auth.HEADER.size + 16
    for _ in range(4):
        _, offset = auth.read_varint(raw, offset)
    size, offset = auth.read_varint(raw, offset)
    if offset + size != len(raw):
        raise ValueError('invalid standard-route payload length')
    body = auth.unwrap_tlv(raw[offset:], 192)
    fields, offset = [], 0
    while offset < len(body):
        tag, offset = auth.read_varint(body, offset)
        size, offset = auth.read_varint(body, offset)
        if size > len(body) - offset or len(fields) >= 16:
            raise ValueError('invalid capability field length or count')
        value = body[offset:offset + size]
        item = {'tag': tag, 'bytes': size}
        # Only the documented numeric capability bitmask is emitted. Other
        # values may contain device information and remain length-only.
        if tag == 234 and 1 <= size <= 8 and value.isdigit():
            item['capability_bits'] = int(value)
        fields.append(item)
        offset += size
    summary['fields'] = fields
    return summary


def probe(peer_ip, port):
    result = {'session': 'IShareAuthSession', 'capability_responses': [],
              'authentication_complete': False, 'file_offer_sent': False,
              'file_data_sent': False, 'live_icon_verified': False}
    device_hash = secrets.token_hex(8).upper().encode('ascii')
    opening = json.loads(auth.opening(device_hash[:12].decode())[24:].rstrip(b'\0'))
    opening['SRC_BUS_NAME'] = opening['DST_BUS_NAME'] = 'IShareAuthSession'
    process = subprocess.Popen(
        ['/usr/bin/nc', '-G', '3', '-w', '6', peer_ip, str(port)],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    try:
        process.stdin.write(auth.frame(8, 1, json.dumps(opening, separators=(',', ':')).encode() + b'\0'))
        process.stdin.flush()
        response = auth.summarize(auth.read_frame(process, 4))
        result['opening'] = response
        if (response.get('module'), response.get('flags'), response.get('code')) != (8, 1, 4):
            raise ValueError('standard session opening was not acknowledged')
        process.stdin.write(capability_packet(device_hash))
        process.stdin.flush()
        result['capability_request_sent'] = True
        for _ in range(2):
            result['capability_responses'].append(summarize_response(auth.read_frame(process, 3)))
    except (ValueError, OSError) as error:
        # Do not expose OS exception strings, which can include peer addresses.
        result['stop_reason'] = str(error) if isinstance(error, ValueError) else 'transport error'
    finally:
        process.terminate()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=3)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--peer-ip', required=True, help='explicit test phone on the active LAN')
    parser.add_argument('--port', required=True, type=int, help='current advertised phone port')
    parser.add_argument('--interface', default='en0')
    parser.add_argument('--output', type=Path, help='optional redacted result')
    args = parser.parse_args()
    if sys.platform != 'darwin' or not auth.private_ipv4(args.peer_ip) or not 1 <= args.port <= 65535:
        parser.error('Use macOS, a private test-phone IP, and an advertised port')
    source = next((item for item in auth.interfaces()
                   if item.interface == args.interface and ipaddress.ip_address(args.peer_ip) in item.network), None)
    if source is None or source.address == args.peer_ip:
        parser.error('Peer must be another device on the selected active LAN subnet')
    route = subprocess.run(['/sbin/route', '-n', 'get', args.peer_ip],
                           capture_output=True, text=True, timeout=3)
    if not any(line.strip() == f'interface: {args.interface}' for line in route.stdout.splitlines()):
        parser.error('Current route does not use the selected LAN interface')
    result = probe(args.peer_ip, args.port)
    rendered = json.dumps(result, indent=2) + '\n'
    if args.output:
        args.output.write_text(rendered)
    print(rendered, end='')


if __name__ == '__main__':
    main()
