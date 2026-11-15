#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""QA only: exercise the unchanged macOS anDrop RSA/AES/DFile receiver.

The one injected MetaNode notification follows the observed phone ordering;
the Mac receiver normally waits for that notification from an Apple sender.
No physical phone, multicast, vendor binary, account or private file is used.
"""
import argparse
import importlib.util
import json
from pathlib import Path
import select
import signal
import sys

p = argparse.ArgumentParser()
p.add_argument('--reference', type=Path, required=True)
p.add_argument('--address', required=True)
p.add_argument('--output', type=Path, required=True)
p.add_argument('--destination', type=Path, required=True)
p.add_argument('--mode', choices=['accept', 'decline', 'tamper', 'cancel'], default='accept')
a = p.parse_args()
signal.alarm(90)
sys.path.insert(0, str(a.reference / 'Sources'))
from huawei_tcp import TCPListener

def module(name):
    spec = importlib.util.spec_from_file_location(name.replace('-', '_'), a.reference / 'scripts' / (name + '.py'))
    value = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = value
    spec.loader.exec_module(value)
    return value

receiver = module('huawei-receive-probe')
channels = module('huawei-receive-channels')
t = receiver.transfer
state = {}
children = []

def save():
    a.output.write_text(json.dumps(state))

class PhoneOrdering:
    """Keep the reference decoders untouched; initiate phone metadata once."""
    def __init__(self, socket, key):
        self.socket, self.key, self.injected = socket, key, False
        self.stdin = self
        self.stdout = socket.stdout
    def write(self, data):
        self.socket.write(data)
        if not self.injected:
            try:
                body = t.decrypt_frame(data, self.key)
                logical = t.tlvs(body)[0][0] == 10
            except (ValueError, IndexError):
                logical = False
            if logical:
                self.injected = True
                plain = json.dumps({'DEVICE_NAME': 'QA receiver', 'DEVICE_TYPE_ID': 14,
                                    'META_NODE_ID': 'A' * 64, 'FLAG': 100}).encode()
                self.socket.write(t.channel_frame(self.key, (t.META_INFO, 5, 0, 0, 0), plain, 0))
        return len(data)
    def flush(self):
        self.socket.flush()

class FileListener(TCPListener):
    def write(self, data):
        if a.mode == 'tamper' and data[0] == 6:
            altered = bytearray(data)
            altered[-13] ^= 1  # Authenticated DONE tag; keep nonce/framing valid.
            data = bytes(altered)
        return super().write(data)

try:
    listener = TCPListener(a.address)
    children.append(listener)
    state.update(port=listener.port, host=a.address)
    save()
    if not select.select([listener.stdout], [], [], 60)[0]:
        raise TimeoutError('QA client did not connect')
    if listener.peer_address() != a.address:
        raise ValueError('QA must remain on this host')
    opening = t.auth.read_frame(listener)
    def receive(device_hash, key):
        batch = t.batch_files.IncomingBatch(state['accepted_file_count'], state['accepted_total_bytes'])
        channels.receive(t, PhoneOrdering(listener, key), device_hash, key, a.address, a.address, children,
                         a.destination, state, save, batch, listener_factory=FileListener)
    receiver.inspect_offer(listener, opening, state, save, receive=receive, accept_bounded_files=True, approve=lambda: a.mode != 'decline')
    state['success'] = state.get('dfile_done_ack_verified') is True
    save()
    if not state['success']:
        raise RuntimeError('Missing authenticated DONE ACK')
except Exception as error:
    state['error'] = type(error).__name__
    save()
    if a.mode == 'accept':
        raise
finally:
    for child in children:
        child.close()
