# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 anDrop contributors
"""Concurrent production senders with isolated BLE peers and real loopback TLS."""
import asyncio
import io
import json
from pathlib import Path
import ssl
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
import uuid
from unittest.mock import patch
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Sources'))
from aiohttp import ClientSession
from engine import Engine, Keys, parse_wire, wire


class MultiSendTests(unittest.IsolatedAsyncioTestCase):
    async def exercise(self, outcome='complete', mixed=False):
        engine = Engine(); engine.discovering = True
        ids = [uuid.uuid4().hex, uuid.uuid4().hex]
        peers = ['huawei:fixture' if mixed else 'phone-a', 'phone-b']
        events, jobs, downloads, clients = [], [], {}, {}
        started = set(); ready = asyncio.Event()
        proceed = asyncio.Event()

        def mark_started(peer):
            started.add(peer)
            if len(started) == 2: ready.set()

        async def receiver(ble, host, port):
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
            context.check_hostname = False; context.verify_mode = ssl.CERT_NONE
            async with ClientSession() as client:
                async with client.ws_connect(f'https://{host}:{port}/websocket', ssl=context) as ws:
                    ble.callback(None, json.dumps({'wlan': 'wlan', 'wlan_accept': True, 'ip': ble.keys.encrypt('127.0.0.1')}).encode())
                    async for message in ws:
                        if message.type.name != 'TEXT': continue
                        _, index, action, data = parse_wire(message.data)
                        if action in ('wlanBandwidth', 'versionNegotiation'):
                            await ws.send_str(wire('ack', index, action, {}))
                        elif action == 'sendRequest':
                            async with client.get(f'https://{host}:{port}/download', params={'taskId': data['id']}, ssl=context) as response:
                                self.assertEqual(response.status, 200)
                                downloads[ble.peer] = await response.read()
                            await ws.send_str(wire('action', 10, 'status', {'taskId': data['id'], 'type': 1}))
                            break

        class BLE:
            def __init__(self, device, **kwargs):
                self.peer = device.address; self.keys = Keys(); self.is_connected = False
                clients[self.peer] = self
            async def connect(self): self.is_connected = True
            async def disconnect(self): self.is_connected = False
            async def read_gatt_char(self, *_): return json.dumps({'state': 0, 'key': self.keys.public}).encode()
            async def start_notify(self, _, callback): self.callback = callback
            async def write_gatt_char(self, _, raw, **kwargs):
                if raw == b'cancel': return
                data = json.loads(raw)
                if 'key' in data:
                    self.keys.derive(data['key']); mark_started(self.peer)
                    await ready.wait()  # Neither transfer can complete before both start.
                    await proceed.wait()
                    if self.peer == peers[0] and outcome == 'declined': self.callback(None, b'3'); return
                    if self.peer == peers[0] and outcome == 'cancelled': return
                    self.callback(None, json.dumps({'wlan': 'wlan', 'ip': self.keys.encrypt('192.168.49.1')}).encode())
                else:
                    jobs.append(asyncio.create_task(receiver(self, self.keys.decrypt(data['ip']), int(self.keys.decrypt(data['port'])))))

        popen = subprocess.Popen
        def huawei_worker(command, *args, **kwargs):
            if '--peer-ip' not in command: return popen(command, *args, **kwargs)
            mark_started(peers[0])
            output = Path(command[command.index('--output') + 1])
            exited = False
            def poll():
                nonlocal exited
                if exited: return 0
                if not proceed.is_set(): return None
                output.write_text(json.dumps({'dfile_transfer_done_received': True}))
                exited = True
                return 0
            return SimpleNamespace(pid=99999999, stdin=None, stdout=None, poll=poll, wait=lambda timeout: 0)

        for peer in peers:
            if peer.startswith('huawei:'):
                engine.huawei.peers[peer] = {'id': peer, 'host': '192.168.1.2', 'port': 33651, 'last': time.monotonic(), 'name': 'Fixture', 'brand': 'Huawei', 'kind': 'phone'}
            else:
                engine.devices[peer] = SimpleNamespace(address=peer)
                engine.peers[peer] = {'name': peer, 'last': time.monotonic()}
        with tempfile.TemporaryDirectory() as folder:
            fixtures = {'日本語.txt': b'multi-send fixture', 'empty.bin': b'', 'payload.bin': bytes(range(256)) * 8192}
            paths = []
            for name, content in fixtures.items():
                path = Path(folder) / name; path.write_bytes(content); paths.append(str(path))
            with (patch('engine.BleakClient', BLE), patch('engine.lan_addresses', return_value=['127.0.0.1']),
                  patch('engine.private_ipv4', side_effect=lambda address: address == '127.0.0.1'),
                  patch('engine.emit', side_effect=lambda event, **value: events.append({'event': event, **value})),
                  patch('huawei_runtime.subprocess.Popen', side_effect=huawei_worker)):
                tasks = [asyncio.create_task(engine.command({'command': 'send', 'peer': peer, 'paths': paths, 'request_id': identifier}))
                         for peer, identifier in zip(peers, ids)]
                try:
                    await asyncio.wait_for(ready.wait(), 5)
                    self.assertEqual(set(engine.outgoing), set(ids))
                    self.assertIsNone(engine.session)
                    await engine.command({'command': 'send', 'peer': peers[1], 'paths': paths, 'request_id': ids[1]})
                    # Duplicate destination and malformed requests cannot disrupt siblings.
                    await engine.command({'command': 'send', 'peer': peers[1], 'paths': paths, 'request_id': uuid.uuid4().hex})
                    await engine.command({'command': 'send', 'peer': peers[1], 'paths': paths, 'request_id': 'invalid'})
                    self.assertEqual(set(engine.outgoing), set(ids))
                    if outcome == 'cancelled': await engine.command({'command': 'cancel', 'id': ids[0]})
                    proceed.set()
                    await asyncio.wait_for(asyncio.gather(*tasks, return_exceptions=True), 8)
                    for identifier, expected in zip(ids, [outcome, 'complete']):
                        terminal = [event['state'] for event in events if event.get('id') == identifier and event.get('state') in ('complete', 'declined', 'cancelled', 'failed')]
                        self.assertEqual(terminal, [expected], str(events))
                    self.assertFalse(engine.busy, str(engine.outgoing))
                    self.assertFalse(engine.outgoing)
                    self.assertFalse(engine.huawei.senders)
                    self.assertTrue(all(not client.is_connected for client in clients.values()))
                    self.assertEqual(events[-1]['value']['state'], 0)
                    for peer, archive in downloads.items():
                        with zipfile.ZipFile(io.BytesIO(archive)) as zipped:
                            self.assertEqual(set(zipped.namelist()), set(fixtures))
                            for name, content in fixtures.items(): self.assertEqual(zipped.read(name), content)
                    expected_downloads = set(peers[1:]) if mixed or outcome != 'complete' else set(peers)
                    self.assertEqual(set(downloads), expected_downloads)
                finally:
                    for task in tasks + jobs: task.cancel()
                    await asyncio.gather(*tasks, *jobs, return_exceptions=True)

    async def test_two_recipients_download_identical_contents_concurrently(self): await self.exercise()
    async def test_one_decline_does_not_fail_the_other(self): await self.exercise('declined')
    async def test_cancelling_one_does_not_cancel_the_other(self): await self.exercise('cancelled')
    async def test_huawei_worker_and_oshare_sender_overlap(self): await self.exercise(mixed=True)
    async def test_huawei_cancel_does_not_cancel_oshare_sender(self): await self.exercise('cancelled', mixed=True)


if __name__ == '__main__': unittest.main()
