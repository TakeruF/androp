#!/usr/bin/env python3
"""Bounded LAN receiver experiment; optional known-fixture reception, no pairing.

Announces a synthetic PC to one explicitly selected same-LAN phone. Captures
structural metadata, never peer identifiers. Inspection rejects offers; explicit
--receive-fixture accepts only the known synthetic file for content verification.
--accept-files explicitly auto-accepts one batch with count/size/name bounds.
"""
import argparse
import importlib.util
import ipaddress
import json
import os
from pathlib import Path
import secrets
import select
import socket
import subprocess
import time

spec = importlib.util.spec_from_file_location('huawei_auth', Path(__file__).with_name('huawei-auth-probe.py'))
auth = importlib.util.module_from_spec(spec)
spec.loader.exec_module(auth)


def advertisement(address, port, identity, sequence, mode=10):
    if not auth.private_ipv4(address) or not 1 <= port <= 65535 or mode not in (1, 10):
        raise ValueError('invalid private listener endpoint')
    value = {'deviceId': json.dumps({'UDID': identity}, separators=(',', ':')),
             'devicename': 'anDrop LAN Probe', 'type': 12, 'hicomversion': '', 'mode': mode,
             # SoftBus maps this field to hwAccountHashVal, not a public-key hash.
             # This probe has no Huawei account identity.
             'deviceHash': '', 'serviceData': f'port:{port},',
             'extendServiceData': 'osType:2,nbVer:9,rssi:-58,abl:8', 'wlanIp': address,
             'capabilityBitmap': [256], 'coapUri': f'coap://{address}:5684/device_discover',
             'bType': 5, 'seqNo': sequence}
    if mode == 10:
        del value['coapUri']
    return (b'\x42\x02' + secrets.token_bytes(4) + b'\xbd\x02device_discover\x11\x32\xff'
            + json.dumps(value, separators=(',', ':')).encode())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--peer-ip', required=True)
    parser.add_argument('--seconds', type=int, default=45)
    parser.add_argument('--mode', type=int, choices=(1, 10), default=10)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--inspect-offer', action='store_true', help='exchange ephemeral keys, inspect then reject the offer; no file data')
    parser.add_argument('--receive-fixture', action='store_true', help='accept only count=1 / 77 bytes, then verify fixed fixture filename and content')
    parser.add_argument('--fixture-source', type=Path, help='local reference fixture: name, size and SHA-256 must match; at most 8 MiB')
    parser.add_argument('--reference-file', type=Path, action='append', help='explicit reference set; repeat for 1..16 files, saved in a new .received directory')
    parser.add_argument('--accept-files', action='store_true', help='explicitly accept one bounded batch from the selected phone without local references; experimental auto-accept')
    parser.add_argument('--cancel-after-preview', action='store_true', help='test receiver cancellation before accepting the file data')
    args = parser.parse_args()
    if args.accept_files:
        if args.reference_file or args.fixture_source or args.receive_fixture or args.cancel_after_preview:
            parser.error('bounded acceptance cannot be combined with reference or cancel modes')
        args.receive_fixture = True
    if args.reference_file:
        if args.fixture_source:
            parser.error('select either a legacy fixture source or reference files')
        args.receive_fixture = True
    if args.cancel_after_preview:
        args.receive_fixture = True
    if args.fixture_source:
        args.receive_fixture = True
    expected = None
    if args.receive_fixture:
        channel_spec = importlib.util.spec_from_file_location('huawei_receive_channels', Path(__file__).with_name('huawei-receive-channels.py'))
        receiver_channels = importlib.util.module_from_spec(channel_spec)
        channel_spec.loader.exec_module(receiver_channels)
        expected = receiver_channels.FixtureSpec.from_path(args.fixture_source) if args.fixture_source else receiver_channels.FixtureSpec()
        if args.reference_file or args.accept_files:
            batch_spec = importlib.util.spec_from_file_location('huawei_file_batch', Path(__file__).with_name('huawei-file-batch.py'))
            batch_module = importlib.util.module_from_spec(batch_spec)
            batch_spec.loader.exec_module(batch_module)
            expected = batch_module.Batch.from_paths(args.reference_file) if args.reference_file else None
    destination = args.output.with_suffix('.received' if args.reference_file or args.accept_files else '.received.txt')
    if args.receive_fixture:
        args.inspect_offer = True
        if destination.exists() or destination.is_symlink():
            parser.error('fixture destination already exists')
    if not auth.private_ipv4(args.peer_ip) or not 1 <= args.seconds <= 60:
        parser.error('explicit private peer and 1..60 seconds required')
    source = next((v for v in auth.interfaces() if v.interface == 'en0'
                   and ipaddress.ip_address(args.peer_ip) in v.network), None)
    route = subprocess.run(['/sbin/route', '-n', 'get', args.peer_ip], capture_output=True, text=True, timeout=3)
    if not source or source.address == args.peer_ip or 'interface: en0' not in route.stdout:
        parser.error('peer must be on existing en0 LAN')
    with socket.socket() as reservation:
        reservation.bind((source.address, 0))
        port = reservation.getsockname()[1]
    processes = []
    result = {'pc_type': 12, 'mode': args.mode, 'advertisements_sent': 0, 'discovery_response_chunks': 0,
              'tcp_opening_received': False, 'authentication_complete': False, 'file_received': False}
    def save():
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, indent=2) + '\n')
    try:
        listener = subprocess.Popen(['/usr/bin/nc', '-l', source.address, str(port)], stdin=subprocess.PIPE,
                                    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        processes.append(listener)
        discovery = subprocess.Popen(['/usr/bin/nc', '-u', '-s', source.address, '-p', '5684',
                                      args.peer_ip, '5684'], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.DEVNULL)
        processes.append(discovery)
        deadline, next_ad, identity = time.monotonic() + args.seconds, 0, secrets.token_hex(32).upper()
        private = None
        if args.inspect_offer:
            from cryptography.hazmat.primitives.asymmetric import rsa
            from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
            private = rsa.generate_private_key(public_exponent=65537, key_size=2048)
            public = private.public_key().public_bytes(Encoding.DER, PublicFormat.SubjectPublicKeyInfo)
            # HarmonyOS 7 emulator ProtocolV2 compares the first six HMAC bytes
            # as ordinary hex, without Petal's per-uint16 byte reversal.
            result['protocol_v2_key_bound_identity'] = True
            identity = auth.protocol_v2_identity(public)
        print('Synthetic PC listener active; ' + ('explicit bounded batch acceptance enabled.' if args.accept_files else
              ('reference fixture reception enabled.' if args.receive_fixture else 'no automatic file acceptance.')), flush=True)
        while time.monotonic() < deadline:
            if listener.poll() is not None or discovery.poll() is not None:
                result['transport_ended'] = True
                break
            if time.monotonic() >= next_ad:
                result['advertisements_sent'] += 1
                discovery.stdin.write(advertisement(source.address, port, identity, result['advertisements_sent'], args.mode))
                discovery.stdin.flush()
                next_ad = time.monotonic() + 2
            ready, _, _ = select.select([listener.stdout, discovery.stdout], [], [], .2)
            if listener.stdout in ready:
                frame = auth.read_frame(listener, min(3, max(.01, deadline-time.monotonic())))
                result['tcp_opening_received'] = True
                result['opening'] = auth.summarize(frame)
                save()
                if args.inspect_offer:
                    connections = subprocess.run(['/usr/sbin/lsof', '-nP', '-a', '-p', str(listener.pid),
                                                  '-iTCP', '-sTCP:ESTABLISHED', '-Fn'],
                                                 capture_output=True, text=True, timeout=3)
                    peers = [line.split('->', 1)[1].rsplit(':', 1)[0]
                             for line in connections.stdout.splitlines() if line.startswith('n') and '->' in line]
                    if peers != [args.peer_ip]:
                        raise ValueError('incoming peer does not match selected LAN target')
                    result['incoming_peer_matches_target'] = True
                    module_spec = importlib.util.spec_from_file_location('huawei_receive', Path(__file__).with_name('huawei-receive-probe.py'))
                    receiver = importlib.util.module_from_spec(module_spec)
                    module_spec.loader.exec_module(receiver)
                    receive = None
                    if args.receive_fixture:
                        def receive(device_hash, key):
                            selected = (receiver.transfer.batch_files.IncomingBatch(result['accepted_file_count'], result['accepted_total_bytes'])
                                        if args.accept_files else expected)
                            receiver_channels.receive(receiver.transfer, listener, device_hash, key,
                                source.address, args.peer_ip, processes, destination, result, save, selected, args.cancel_after_preview)
                    receiver.inspect_offer(listener, frame, result, save, private=private, receive=receive,
                        expected_size=expected.size if expected else 77, expected_count=getattr(expected, 'count', 1),
                        accept_bounded_files=args.accept_files)
                break
            if discovery.stdout in ready:
                raw = os.read(discovery.stdout.fileno(), 8192)
                if not raw:
                    break
                result['discovery_response_chunks'] += 1
                if len(raw) >= 4 and raw[0] >> 6 == 1 and (raw[0] >> 4) & 3 == 0:
                    discovery.stdin.write(b'\x60\x00' + raw[2:4])
                    discovery.stdin.flush()
    except (ValueError, OSError) as error:
        result['error_type'] = type(error).__name__
        if isinstance(error, ValueError):
            result['error_reason'] = str(error)
    finally:
        for process in processes:
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
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps(result))


if __name__ == '__main__':
    main()
