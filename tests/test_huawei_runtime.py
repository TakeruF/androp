# SPDX-License-Identifier: GPL-3.0-only
import asyncio
import base64
import ipaddress
import json
import os
from pathlib import Path
import sys
import tempfile
import subprocess
import select
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Sources'))
from engine import Engine
import huawei_runtime
from huawei_runtime import advertisement, decode_advertisement, publish_files, place_exclusive

LOCAL = SimpleNamespace(address='192.168.30.2', interface='en0', network=ipaddress.ip_network('192.168.30.0/24'))
HOST = '192.168.30.3'


def packet(**changes):
    wire = advertisement(HOST, 33651, 'test-ephemeral-id', 'Huawei test', True)
    marker = wire.index(b'\xff', 6)
    value = json.loads(wire[marker + 1:]); value.update(type=14, extendServiceData='osType:0,nbVer:9,rssi:-58,abl:8'); value.update(changes)
    return wire[:marker + 1] + json.dumps(value).encode()


class ReceiveDiagnostics(unittest.TestCase):
    def test_failure_site_omits_messages_paths_and_unrecognized_modules(self):
        for filename, expected in [('/private/huawei-receive-channels.py', {'receive_module': 'channels', 'receive_line': 1}),
                                   ('/private/user-data.py', {})]:
            try:
                exec(compile("raise ValueError('private name and address')", filename, 'exec'))
            except ValueError as error:
                self.assertEqual(huawei_runtime.receive_failure_site(error), expected)
    def test_preview_diagnostics_exports_only_bounded_shape(self):
        def state(fields):
            return {'preview_issue': 'thumbnail_size', 'byte_data': [{'tlvs': [{'tag': 8, 'fields': fields}]}]}
        result = huawei_runtime.preview_diagnostics(state([{'tag': 11, 'bytes': 18, 'value': 'private.jpg'}, {'tag': 12, 'bytes': 60001}]))
        self.assertEqual(result, {'preview_issue': 'thumbnail_size', 'preview_fields': [{'tag': 11, 'bytes': 18}, {'tag': 12, 'bytes': 60001}]})
        for fields in ([{'tag': 11, 'bytes': -1}], [{'tag': 256, 'bytes': 1}], [{'tag': 12, 'bytes': 1048577}],
                       [{'tag': 11, 'bytes': 'private.jpg'}], [{'tag': True, 'bytes': 1}], [{'tag': 11, 'bytes': 1}] * 33):
            self.assertNotIn('preview_fields', huawei_runtime.preview_diagnostics(state(fields)))
        self.assertEqual(huawei_runtime.preview_diagnostics({'preview_issue': 'private.jpg'}), {})
        self.assertEqual(huawei_runtime.preview_diagnostics({}), {})

    def test_receive_failure_phase_is_fixed_and_never_contains_remote_text(self):
        self.assertEqual(huawei_runtime.receive_error_phase(ValueError('unsupported batch preview')), 'receive_preview')
        self.assertEqual(huawei_runtime.receive_error_phase(ValueError('unsupported byte data frame')), 'receive_preview_frame')
        self.assertEqual(huawei_runtime.receive_error_phase(ValueError('batch metadata total differs from accepted offer')), 'receive_metadata')
        self.assertEqual(huawei_runtime.receive_error_phase(ValueError('unexpected batch DATA file ID')), 'receive_data')
        for error in (ValueError('unsupported batch preview /private/photo.jpg'), OSError('private name 192.168.0.4')):
            self.assertEqual(huawei_runtime.receive_error_phase(error), 'receive')


class DiscoveryValidation(unittest.TestCase):
    def test_structured_port_is_bound_to_kernel_source_and_selected_subnet(self):
        peer, confirmable, message_id = decode_advertisement(packet(), HOST, LOCAL)
        self.assertEqual(peer['port'], 33651)
        self.assertEqual(peer['host'], HOST)
        self.assertEqual(peer['brand'], 'Huawei')
        self.assertTrue(confirmable)
        self.assertTrue(peer['id'].startswith('huawei:'))
        self.assertEqual(decode_advertisement(packet() + b'\0', HOST, LOCAL)[0]['port'], 33651)
        for raw, host in [(packet(wlanIp='192.168.30.99'), HOST), (packet(), '10.0.0.4'),
                          (packet(serviceData='port:33651,port:4444,'), HOST),
                          (packet(serviceData='junkport:4444,'), HOST), (packet(serviceData='port:0,'), HOST),
                          (packet(serviceData='port:65536,'), HOST), (packet(serviceData='port:4444/path,'), HOST),
                          (packet(bType=1), HOST), (packet(capabilityBitmap=[]), HOST),
                          (packet() + b'garbage', HOST), (packet()[:45], HOST),
                          (packet() + b'\0\0', HOST), (packet() + b'\0{}', HOST),
                          (b'junk' + packet(), HOST)]:
            with self.subTest(raw=raw[:8], host=host):
                with self.assertRaises(ValueError): decode_advertisement(raw, host, LOCAL)
    def test_duplicate_json_and_wrong_coap_resource_are_rejected(self):
        raw = packet(); marker = raw.index(b'\xff', 6)
        duplicated = raw[:marker + 1] + raw[marker + 1:-1] + b',"wlanIp":"192.168.30.3"}'
        with self.assertRaises(ValueError): decode_advertisement(duplicated, HOST, LOCAL)
        with self.assertRaises(ValueError): decode_advertisement(raw.replace(b'device_discover', b'other_discovery'), HOST, LOCAL)
    def test_native_uri_host_without_content_format_is_bound_to_lan_pair(self):
        raw = packet(); marker = raw.index(b'\xff', 6)
        hostname = LOCAL.address.encode()
        options = bytes([0x30 | len(hostname)]) + hostname + b'\x8d\x02device_discover'
        native = raw[:6] + options + raw[marker:]
        self.assertEqual(decode_advertisement(native, HOST, LOCAL)[0]['port'], 33651)
        group = str(LOCAL.network.broadcast_address).encode()
        group_options = (bytes([0x30 | len(group)]) if len(group) < 13 else bytes([0x3d, len(group) - 13])) + group + b'\x8d\x02device_discover'
        self.assertEqual(decode_advertisement(raw[:6] + group_options + raw[marker:], HOST, LOCAL)[0]['host'], HOST)
        with self.assertRaises(ValueError):
            decode_advertisement(native.replace(hostname, b'203.0.113.99', 1), HOST, LOCAL)
    def test_idle_phone_without_share_bit_is_listed_but_unknown_types_need_it(self):
        # Measured on HarmonyOS 7: an idle Pura answers with capabilityBitmap [192].
        self.assertEqual(decode_advertisement(packet(capabilityBitmap=[192]), HOST, LOCAL)[0]['kind'], 'phone')
        self.assertEqual(decode_advertisement(packet(capabilityBitmap=[192], type=17), HOST, LOCAL)[0]['kind'], 'tablet')
        self.assertEqual(decode_advertisement(packet(capabilityBitmap=[448], type=156), HOST, LOCAL)[0]['kind'], 'unknown')
        for changes in ({'type': 156}, {'type': True}, {'type': '14'}, {'type': 14.0}):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                decode_advertisement(packet(capabilityBitmap=[192], **changes), HOST, LOCAL)
    def test_pc_type_uses_computer_badge_but_needs_share_capability(self):
        peer = decode_advertisement(packet(type=12), HOST, LOCAL)[0]
        self.assertEqual(peer['kind'], 'computer')
        self.assertEqual(peer['brand'], 'Huawei')
        # Only the measured mobile types get the idle-without-SHARE exception.
        with self.assertRaises(ValueError):
            decode_advertisement(packet(type=12, capabilityBitmap=[192]), HOST, LOCAL)

    def test_existing_mac_advertisement_is_apple_without_changing_transport_identity(self):
        for discovering in (False, True):
            # Exercise the real outbound packet, including older anDrop builds
            # that already published this shape. Names are not model evidence.
            raw = advertisement(HOST, 33651, 'test-ephemeral-id', 'Office', discovering)
            peer = decode_advertisement(raw, HOST, LOCAL)[0]
            self.assertEqual((peer['brand'], peer['kind'], peer['name']), ('Apple', 'computer', 'Office'))
            huawei = decode_advertisement(packet(type=12), HOST, LOCAL)[0]
            self.assertEqual(peer['id'], huawei['id'])
            self.assertEqual(peer['port'], huawei['port'])

    def test_mac_hint_requires_pc_and_one_exact_os_type(self):
        for extension in (None, {}, 2, '', 'osType:0', 'osType:1', 'osType:20',
                          'otherosType:2', 'osType:2,osType:0', 'osType:2,osType:2', 'osType:2,' + 'x' * 256):
            with self.subTest(extension=extension):
                peer = decode_advertisement(packet(type=12, devicename='MacBook Air', extendServiceData=extension), HOST, LOCAL)[0]
                self.assertEqual(peer['brand'], 'Huawei')
        for kind in (14, 17, 156):
            self.assertEqual(decode_advertisement(packet(type=kind, extendServiceData='osType:2'), HOST, LOCAL)[0]['brand'], 'Huawei')
        peer = decode_advertisement(packet(type=12, extendServiceData='nbVer:9,osType:2,abl:8'), HOST, LOCAL)[0]
        self.assertEqual(peer['brand'], 'Apple')

    def test_mac_hint_is_display_metadata_and_does_not_grant_trust(self):
        engine = Engine(); runtime = engine.huawei; engine.discovering = True
        runtime.local = LOCAL; runtime.enabled = True; runtime.port = 12345; runtime.identity = 'local-test'
        raw = advertisement(HOST, 33651, 'test-ephemeral-id', 'Office')
        with patch.object(runtime, 'emit'), patch('engine.emit'):
            runtime.datagram({'local': LOCAL.address, 'host': HOST, 'port': 5684, 'data': base64.b64encode(raw).decode()})
        self.assertEqual(runtime.visible_peers()[0]['brand'], 'Apple')
        self.assertEqual(engine.trusted_ids, set())

    def test_rejections_report_fixed_codes_and_ignore_bare_acks(self):
        engine = Engine(); runtime = engine.huawei
        runtime.local = LOCAL; runtime.enabled = True; runtime.port = 12345; runtime.identity = 'local-test'
        cases = [(packet(bType=1), 'discovery_address'), (packet(capabilityBitmap=[192], type=156), 'discovery_record'),
                 (packet(serviceData='port:0,'), 'discovery_port'), (b'\x60\x00\x12\x34', None), (packet()[:-5], 'malformed')]
        for raw, code in cases:
            with self.subTest(code=code), patch.object(runtime, 'emit') as emitted:
                runtime.last_rejection = 0
                runtime.datagram({'local': LOCAL.address, 'host': HOST, 'port': 5684, 'data': base64.b64encode(raw).decode()})
                phases = [c.kwargs.get('phase') for c in emitted.call_args_list if c.kwargs.get('detail') == 'huawei_discovery_rejected']
                self.assertEqual(phases, [code] if code else [])
    def test_fresh_discovery_updates_endpoint_without_persistent_trust(self):
        engine = Engine(); runtime = engine.huawei
        runtime.local = LOCAL; runtime.enabled = True; runtime.port = 12345; runtime.identity = 'local-test'
        with patch.object(runtime, 'emit') as emitted:
            runtime.datagram({'local': LOCAL.address, 'host': HOST, 'port': 5684, 'data': base64.b64encode(packet()).decode()})
            runtime.datagram({'local': LOCAL.address, 'host': HOST, 'port': 5684, 'data': base64.b64encode(packet(serviceData='port:4455,')).decode()})
        self.assertEqual(len(runtime.peers), 1)
        self.assertEqual(next(iter(runtime.peers.values()))['port'], 4455)
        self.assertEqual(engine.trusted_ids, set())
        self.assertEqual(sum(c.args[0] == 'huawei_datagram' for c in emitted.call_args_list), 3)  # two ACKs, one rate-limited reply
    def test_reply_to_phone_publishes_receiver_even_while_picker_is_open(self):
        engine = Engine(); runtime = engine.huawei; engine.discovering = True
        runtime.local = LOCAL; runtime.enabled = True; runtime.port = 12345; runtime.identity = 'local-test'
        with patch.object(runtime, 'emit') as emitted:
            runtime.datagram({'local': LOCAL.address, 'host': HOST, 'port': 5684, 'data': base64.b64encode(packet()).decode()})
        replies = [base64.b64decode(c.kwargs['data']) for c in emitted.call_args_list if c.args[0] == 'huawei_datagram' and len(base64.b64decode(c.kwargs['data'])) > 4]
        self.assertEqual(len(replies), 1)
        value = json.loads(replies[0][replies[0].index(b'\xff') + 1:])
        self.assertEqual(value['mode'], 10); self.assertNotIn('coapUri', value)
        self.assertEqual(json.loads(runtime.packet()[runtime.packet().index(b'\xff') + 1:])['mode'], 1)  # broadcasts still discover
        with patch('huawei_runtime.time.monotonic', return_value=next(iter(runtime.peers.values()))['last'] + 10):
            self.assertEqual(runtime.visible_peers(), [])


class ApprovalIntegration(unittest.IsolatedAsyncioTestCase):
    async def test_mac_send_retains_apple_metadata_through_completion(self):
        engine = Engine(); engine.discovering = True
        peer = decode_advertisement(advertisement(HOST, 33651, 'mac-test', 'Office'), HOST, LOCAL)[0]
        engine.huawei.peers[peer['id']] = peer
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder) / 'fixture.txt'; source.write_bytes(b'fixture')
            def launch(command, **kwargs):
                Path(command[command.index('--output') + 1]).write_text(json.dumps({'dfile_transfer_done_received': True}))
                return SimpleNamespace(pid=99999999, stdin=None, stdout=None, poll=lambda: 0, wait=lambda timeout: 0)
            with patch('huawei_runtime.subprocess.Popen', side_effect=launch), patch('engine.emit') as events:
                await engine.send(peer['id'], [str(source)], peer['name'], None)
        completed = [c.kwargs for c in events.call_args_list if c.kwargs.get('state') == 'complete']
        self.assertEqual(len(completed), 1)
        self.assertEqual((completed[0]['device_brand'], completed[0]['device_kind']), ('Apple', 'computer'))

    async def test_mac_receive_uses_apple_metadata_for_approval(self):
        engine = Engine(); runtime = engine.huawei; runtime.local = LOCAL
        runtime.loop = asyncio.get_running_loop()
        peer = decode_advertisement(advertisement(HOST, 33651, 'mac-test', 'Office'), HOST, LOCAL)[0]
        runtime.peers[peer['id']] = peer
        prompts = []
        async def approval(session, result):
            prompts.append((session['brand'], session['kind']))
            return False
        def offer(process, raw, result, save, **kwargs):
            self.assertFalse(kwargs['approve']())
            result['inspection_offer_rejected'] = True
        runtime.receiver = SimpleNamespace(transfer=SimpleNamespace(auth=SimpleNamespace(read_frame=lambda *a: b'')), inspect_offer=offer)
        with tempfile.TemporaryDirectory() as folder:
            engine.destination = folder
            lsof = SimpleNamespace(stdout=f'p1\nn{LOCAL.address}:5555->{HOST}:40000\n')
            with patch('huawei_runtime.subprocess.run', return_value=lsof), patch('engine.emit'), patch.object(runtime, 'approval', side_effect=approval):
                await runtime.receive(SimpleNamespace(pid=1), huawei_runtime.Processes())
        self.assertEqual(prompts, [('Apple', 'computer')])

    async def test_configuration_retains_only_valid_persistent_huawei_keys(self):
        engine = Engine()
        identity = 'huawei-key:' + 'a' * 64
        with patch('engine.emit'):
            await engine.command({'command': 'configure', 'trusted_only': True,
                                  'trusted_ids': [identity, 'huawei:discovery-id', 'huawei-key:' + 'g' * 64]})
        self.assertEqual(engine.trusted_ids, {identity})
        self.assertFalse(engine.may_negotiate('00000000-0000-0000-0000-00000000000B'))
    async def approval(self, accepted, *, trusted=False, revoke=False, identity=None, allowed=None, remove_trust=False):
        engine = Engine(); engine.trusted_only = trusted
        engine.auto_accept_trusted = False
        engine.trusted_ids = set(allowed or [])
        session = {'id': 'test-session', 'central': '', 'direction': 'receive', 'protocol': 'huawei'}
        if identity: session['device_identifier'] = identity
        events = []
        with patch('engine.emit', side_effect=lambda event, **values: events.append({'event': event, **values})):
            task = asyncio.create_task(engine.huawei.approval(session, {'accepted_file_count': 3, 'accepted_total_bytes': 81}))
            await asyncio.sleep(0)
            if not trusted or identity in engine.trusted_ids:
                self.assertEqual(events[-1]['state'], 'request')
                self.assertFalse(task.done())
                if revoke: engine.huawei_enabled = False
                if remove_trust: engine.trusted_ids.clear()
                await engine.command({'command': 'decision', 'id': session['id'], 'accept': accepted})
            result = await task
        self.assertNotIn('complete', [e.get('state') for e in events])
        return result
    async def test_accept_decline_and_revocation_use_existing_decision_flow(self):
        self.assertTrue(await self.approval(True))
        self.assertFalse(await self.approval(False))
        self.assertFalse(await self.approval(True, revoke=True))
        self.assertFalse(await self.approval(True, trusted=True))
    async def test_trusted_huawei_key_requires_approval_and_rechecks_removal(self):
        identity = 'huawei-key:' + 'a' * 64
        self.assertTrue(await self.approval(True, trusted=True, identity=identity, allowed=[identity]))
        self.assertFalse(await self.approval(False, trusted=True, identity=identity, allowed=[identity]))
        self.assertFalse(await self.approval(True, trusted=True, identity=identity, allowed=[identity], remove_trust=True))
        self.assertFalse(await self.approval(True, trusted=True, identity=identity, allowed=[identity], revoke=True))
    async def test_trusted_huawei_key_auto_accepts_in_both_scopes(self):
        identity = 'huawei-key:' + 'a' * 64
        for trusted_only in (False, True):
            for enabled in (False, True):
                engine = Engine(); engine.trusted_only = trusted_only
                engine.trusted_ids = {identity}; engine.huawei_enabled = enabled
                session = {'id': 'auto-huawei', 'central': '', 'direction': 'receive',
                           'protocol': 'huawei', 'device_identifier': identity}
                with patch.object(engine, 'update') as update, patch('engine.emit'):
                    accepted = await engine.huawei.approval(session, {'accepted_file_count': 1, 'accepted_total_bytes': 5})
                self.assertEqual(accepted, enabled)
                self.assertEqual(engine.decisions, {})
                update.assert_not_called()
    async def test_unknown_changed_or_advertised_identity_never_prompts(self):
        identity = 'huawei-key:' + 'a' * 64
        for candidate in (None, 'huawei-key:' + 'b' * 64, 'huawei:advertisement',
                          'sender:' + 'a' * 64, 'huawei-key:' + 'g' * 64):
            with self.subTest(candidate=candidate):
                self.assertFalse(await self.approval(True, trusted=True, identity=candidate, allowed=[identity]))
    async def test_stale_send_does_not_start_worker(self):
        engine = Engine(); engine.discovering = True
        with patch('engine.emit') as events, patch('huawei_runtime.subprocess.Popen') as process:
            await engine.send('huawei:unknown', ['unused'], 'Huawei', None)
        process.assert_not_called()
        self.assertEqual(events.call_args.kwargs['state'], 'failed')
        self.assertIsNone(engine.session)
    async def test_send_worker_uses_immutable_snapshot_not_mutated_original(self):
        engine = Engine(); engine.discovering = True
        peer_id = 'huawei:test'
        engine.huawei.peers[peer_id] = {'id': peer_id, 'host': HOST, 'port': 33651, 'last': time.monotonic(), 'name': 'Huawei', 'brand': 'Huawei', 'kind': 'phone'}
        with tempfile.TemporaryDirectory() as folder:
            original = Path(folder) / '日本語.txt'; original.write_bytes(b'selected content')
            observed = []
            def launch(command, **kwargs):
                snapshot = Path(command[command.index('--send-file') + 1])
                observed.append((snapshot != original, snapshot.read_bytes(), kwargs.get('start_new_session')))
                original.write_bytes(b'changed after selection')
                Path(command[command.index('--output') + 1]).write_text(json.dumps({'dfile_transfer_done_received': True}))
                return SimpleNamespace(pid=99999999, stdin=None, stdout=None, poll=lambda: 0, wait=lambda timeout: 0)
            with patch('huawei_runtime.subprocess.Popen', side_effect=launch), patch('engine.emit') as events:
                await engine.send(peer_id, [str(original)], 'Huawei', None)
            self.assertEqual(observed, [(True, b'selected content', True)])
            self.assertEqual(events.call_args_list[-2].kwargs['state'], 'complete')
            self.assertIsNone(engine.session)
    async def test_cancel_during_snapshot_stops_copier_before_removing_staging(self):
        import threading
        engine = Engine(); engine.discovering = True
        peer_id = 'huawei:test'
        engine.huawei.peers[peer_id] = {'id': peer_id, 'host': HOST, 'port': 33651,
                                       'last': time.monotonic(), 'name': 'Huawei', 'brand': 'Huawei', 'kind': 'phone'}
        entered, finished = threading.Event(), threading.Event()
        staging = []
        def prepare(paths, *, snapshot_dir, stopped):
            staging.append(snapshot_dir)
            entered.set()
            if not stopped.wait(5):
                raise AssertionError('copier did not receive cancellation')
            if not snapshot_dir.is_dir():
                raise AssertionError('staging removed before copier stopped')
            finished.set()
            raise ValueError('send cancelled')
        module = huawei_runtime.protocol('huawei-transfer-probe')
        with (patch('huawei_runtime.protocol', return_value=module),
              patch.object(module.batch_files.Batch, 'from_paths', side_effect=prepare),
              patch('engine.emit') as events, patch('huawei_runtime.subprocess.Popen') as launch):
            task = asyncio.create_task(engine.send(peer_id, ['unused'], 'Huawei', None))
            self.assertTrue(await asyncio.to_thread(entered.wait, 2))
            task.cancel()
            with self.assertRaises(asyncio.CancelledError):
                await task
        self.assertTrue(finished.is_set())
        self.assertFalse(staging[0].exists())
        launch.assert_not_called()
        self.assertIsNone(engine.session)
        self.assertTrue(any(call.kwargs.get('state') == 'cancelled' for call in events.call_args_list))

    def test_cancel_while_worker_exits_is_not_a_permission_failure(self):
        # Darwin killpg() raises EPERM while the group leader is mid-exit,
        # even though poll() still reports it running (measured on macOS 27).
        child = SimpleNamespace(pid=99999999, poll=lambda: None, stdin=None, stdout=None, wait=lambda timeout: 0)
        children = huawei_runtime.Processes(); children.append_group(child)
        with patch('huawei_runtime.os.killpg', side_effect=PermissionError(1, 'Operation not permitted')):
            children.stop()
        self.assertTrue(children.stopped.is_set())
    async def test_cancel_racing_phone_done_reports_complete(self):
        engine = Engine(); engine.discovering = True
        peer_id = 'huawei:test'
        engine.huawei.peers[peer_id] = {'id': peer_id, 'host': HOST, 'port': 33651, 'last': time.monotonic(), 'name': 'Huawei', 'brand': 'Huawei', 'kind': 'phone'}
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder) / 'a.bin'; source.write_bytes(b'x' * 10)
            def launch(command, **kwargs):
                output = Path(command[command.index('--output') + 1])
                output.write_text(json.dumps({'receiver_accepted': True, 'data_bytes_queued': 10, 'file_count': 1, 'total_bytes': 10}))
                def finish():  # DONE lands between the last poll and the cancel.
                    output.write_text(json.dumps({'receiver_accepted': True, 'dfile_transfer_done_received': True, 'file_count': 1, 'total_bytes': 10}))
                asyncio.get_running_loop().call_later(.3, finish)
                return SimpleNamespace(pid=99999999, stdin=None, stdout=None, poll=lambda: None, wait=lambda timeout: 0, kill=lambda: None)
            states = []
            with patch('huawei_runtime.subprocess.Popen', side_effect=launch), patch('huawei_runtime.os.killpg'), \
                 patch('engine.emit', side_effect=lambda event, **v: states.append(v.get('state'))):
                task = asyncio.create_task(engine.send(peer_id, [str(source)], 'Huawei', None))
                await asyncio.sleep(.5)
                await engine.command({'command': 'cancel', 'id': next(iter(engine.outgoing))})
                await asyncio.gather(task, return_exceptions=True)
            self.assertEqual([s for s in states if s in ('complete', 'cancelled', 'failed')], ['complete'])
            self.assertIsNone(engine.session)
    async def test_slow_save_folder_does_not_block_discovery_loop(self):
        engine = Engine(); runtime = engine.huawei; runtime.local = LOCAL
        runtime.peers['huawei:x'] = {'id': 'huawei:x', 'host': HOST, 'port': 1, 'last': time.monotonic(), 'name': 'Huawei', 'brand': 'Huawei', 'kind': 'phone'}
        runtime.receiver = SimpleNamespace(transfer=SimpleNamespace(auth=SimpleNamespace(read_frame=lambda *a: b'')),
                                           inspect_offer=lambda *a, **k: a[2].update(inspection_offer_rejected=True))
        runtime.channels = SimpleNamespace()
        with tempfile.TemporaryDirectory() as folder:
            engine.destination = folder
            lsof = SimpleNamespace(stdout=f'p1\nn{LOCAL.address}:5555->{HOST}:40000\n')
            ticks = []
            async def ticker():
                while True: ticks.append(time.monotonic()); await asyncio.sleep(.05)
            tick = asyncio.create_task(ticker())
            with patch('huawei_runtime.subprocess.run', return_value=lsof), \
                 patch('huawei_runtime.remove_stale_staging', side_effect=lambda _: time.sleep(.5)), patch('engine.emit'):
                await runtime.receive(SimpleNamespace(pid=1), huawei_runtime.Processes())
            tick.cancel()
            self.assertGreaterEqual(len(ticks), 6)  # the loop kept running during the 0.5 s stall
            self.assertEqual(list(Path(folder).iterdir()), [])  # staging removed afterwards
    async def test_send_failures_explain_disconnect_and_first_time_decline(self):
        engine = Engine(); engine.discovering = True
        peer_id = 'huawei:test'
        cases = [({'receiver_accepted': True, 'status': 'incomplete', 'error_type': 'ValueError', 'error_reason': 'DFile send deadline'}, 'interrupted'),
                 ({'receiver_accepted': True, 'status': 'incomplete', 'error_type': 'BrokenPipeError'}, 'interrupted'),
                 ({'status': 'receiver_declined_or_cancelled'}, 'Everyone'),
                 ({'receiver_accepted': True, 'status': 'receiver_declined_or_cancelled'}, 'cancelled the transfer'),
                 ({'status': 'incomplete', 'error_type': 'ValueError', 'error_reason': 'unsupported DFile settings'}, 'Could not prepare')]
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder) / 'a.txt'; source.write_bytes(b'a')
            for state, expected in cases:
                engine.huawei.peers[peer_id] = {'id': peer_id, 'host': HOST, 'port': 33651, 'last': time.monotonic(), 'name': 'Huawei', 'brand': 'Huawei', 'kind': 'phone'}
                def launch(command, **kwargs):
                    Path(command[command.index('--output') + 1]).write_text(json.dumps(state))
                    return SimpleNamespace(pid=99999999, stdin=None, stdout=None, poll=lambda: 0, wait=lambda timeout: 0)
                with self.subTest(expected=expected), patch('huawei_runtime.subprocess.Popen', side_effect=launch), patch('engine.emit') as events:
                    await engine.send(peer_id, [str(source)], 'Huawei', None)
                    failed = [c.kwargs for c in events.call_args_list if c.kwargs.get('state') == 'failed']
                    self.assertEqual(len(failed), 1); self.assertIn(expected, failed[0]['detail'])
    def test_receive_disconnect_is_not_reported_as_invalid_file(self):
        self.assertIn('interrupted', huawei_runtime.error_detail(ValueError('DFile receive deadline'), True))
        self.assertIn('interrupted', huawei_runtime.error_detail(ValueError('byte data connection closed'), True))
        self.assertIn('cancelled', huawei_runtime.error_detail(ValueError('phone cancelled transfer'), True))
        self.assertIn('invalid or unsupported', huawei_runtime.error_detail(ValueError('unsupported DFile receive stage'), True))
    async def test_cancel_routes_to_huawei_and_does_not_send_ble_cancel(self):
        engine = Engine(); gate = asyncio.Event()
        async def operation():
            try: await gate.wait()
            finally: await engine.reset(session)
        task = asyncio.create_task(operation())
        session = {'id': 'cancel-test', 'protocol': 'huawei', 'task': task}; engine.session = session
        await asyncio.sleep(0)
        with patch.object(engine.huawei, 'cancel_receive') as cancel, patch.object(engine, 'notify') as notify, patch('engine.emit'):
            await engine.command({'command': 'cancel', 'id': 'cancel-test'})
        cancel.assert_called_once(); notify.assert_not_called()
        self.assertIsNone(engine.session)


class PersistentIdentity(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory(); self.path = Path(self.folder.name) / 'Huawei' / 'identity.pem'
        self.auth = huawei_runtime.protocol('huawei-auth-probe')
    def tearDown(self): self.folder.cleanup()
    def test_key_is_owner_only_reused_and_rejects_unsafe_files(self):
        from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
        public = lambda k: k.public_key().public_bytes(Encoding.DER, PublicFormat.SubjectPublicKeyInfo)
        first = self.auth.load_identity_key(self.path)
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(public(self.auth.load_identity_key(self.path)), public(first))
        node = self.auth.meta_node_id(public(first))
        self.assertRegex(node, '^[0-9A-F]{64}$'); self.assertEqual(node, self.auth.meta_node_id(public(first)))
        self.assertEqual([p.name for p in self.path.parent.iterdir()], ['identity.pem'])
        os.chmod(self.path, 0o644)
        with self.assertRaises(ValueError): self.auth.load_identity_key(self.path)
        os.chmod(self.path, 0o600)
        link = self.path.with_name('link.pem'); link.symlink_to(self.path)
        with self.assertRaises(OSError): self.auth.load_identity_key(link)
        self.path.write_bytes(b'not a key')
        with self.assertRaises(ValueError): self.auth.load_identity_key(self.path)
    def test_concurrent_first_use_converges_on_one_key(self):
        from concurrent.futures import ThreadPoolExecutor
        from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
        with ThreadPoolExecutor(4) as pool:
            keys = list(pool.map(lambda _: self.auth.load_identity_key(self.path), range(4)))
        self.assertEqual(len({k.public_key().public_bytes(Encoding.DER, PublicFormat.SubjectPublicKeyInfo) for k in keys}), 1)
        self.assertEqual([p.name for p in self.path.parent.iterdir()], ['identity.pem'])
    async def listener_identity(self):
        engine = Engine(); runtime = engine.huawei; runtime.identity_path = self.path; runtime.local = LOCAL
        with patch('huawei_runtime.subprocess.Popen'), patch('socket.socket'), patch.object(runtime, 'emit') as emitted:
            await runtime.open_listener()
            first = (runtime.identity, runtime.node_id)
            await runtime.open_listener()  # A new listener after every session keeps the name.
            self.assertEqual((runtime.identity, runtime.node_id), first)
        return first, runtime.persistent, [c.kwargs.get('detail') for c in emitted.call_args_list]
    async def test_listener_identity_survives_restarts_and_falls_back_when_unusable(self):
        first, persistent, _ = await self.listener_identity()
        self.assertTrue(persistent); self.assertRegex(first[0], '^[0-9A-F]{12}$')
        self.assertEqual((await self.listener_identity())[0], first)
        self.path.write_bytes(b'corrupt'); os.chmod(self.path, 0o600)
        fallback, persistent, details = await self.listener_identity()
        self.assertFalse(persistent); self.assertNotEqual(fallback, first)
        self.assertIn('huawei_identity_unavailable', details)
        self.assertEqual(self.path.read_bytes(), b'corrupt')  # Never silently replaced.
    async def test_send_worker_reuses_identity_only_when_persistent(self):
        engine = Engine(); engine.discovering = True; runtime = engine.huawei
        peer_id = 'huawei:test'
        for persistent in (True, False):
            runtime.peers[peer_id] = {'id': peer_id, 'host': HOST, 'port': 33651, 'last': time.monotonic(), 'name': 'Huawei', 'brand': 'Huawei', 'kind': 'phone'}
            runtime.persistent, runtime.identity_path = persistent, self.path
            commands = []
            def launch(command, **kwargs):
                commands.append(command)
                Path(command[command.index('--output') + 1]).write_text(json.dumps({'dfile_transfer_done_received': True}))
                return SimpleNamespace(pid=99999999, stdin=None, stdout=None, poll=lambda: 0, wait=lambda timeout: 0)
            source = Path(self.folder.name) / 'a.txt'; source.write_bytes(b'a')
            with self.subTest(persistent=persistent), patch('huawei_runtime.subprocess.Popen', side_effect=launch), patch('engine.emit'):
                await engine.send(peer_id, [str(source)], 'Huawei', None)
                self.assertEqual('--identity-key' in commands[0], persistent)
                if persistent: self.assertEqual(commands[0][commands[0].index('--identity-key') + 1], str(self.path))


class DownloadsPublication(unittest.TestCase):
    def test_collision_preserves_existing_and_quarantines_received_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); stage = root / 'stage'; dest = root / 'Downloads'; stage.mkdir(); dest.mkdir()
            (stage / '日本語.txt').write_bytes(b'received'); (stage / 'empty').write_bytes(b'')
            (dest / '日本語.txt').write_bytes(b'existing')
            files = publish_files(stage, dest)
            self.assertEqual((dest / '日本語.txt').read_bytes(), b'existing')
            self.assertEqual((dest / '日本語 (1).txt').read_bytes(), b'received')
            self.assertEqual(len(files), 2)
            import subprocess
            self.assertIn(b'anDrop', subprocess.check_output(['/usr/bin/xattr', '-p', 'com.apple.quarantine', str(dest / '日本語 (1).txt')]))
    def test_stale_staging_from_a_killed_engine_is_removed_but_active_and_foreign_kept(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            stale = root / '.anDrop-Huawei-old'; (stale / 'staging').mkdir(parents=True); (stale / 'staging' / 'a').write_bytes(b'a')
            active = root / '.anDrop-Huawei-new'; active.mkdir()
            user = root / 'anDrop-Huawei-user'; user.mkdir()
            target = root / 'elsewhere'; target.mkdir(); (target / 'keep').write_bytes(b'k')
            link = root / '.anDrop-Huawei-link'; link.symlink_to(target)
            old = time.time() - 3600
            for path in (stale, user): os.utime(path, (old, old))
            os.utime(link, (old, old), follow_symlinks=False)
            self.assertEqual(huawei_runtime.remove_stale_staging(root), 1)
            self.assertFalse(stale.exists())
            self.assertTrue(active.exists() and user.exists() and (target / 'keep').exists() and link.is_symlink())
    def test_publication_failure_rolls_back_only_new_files(self):
        import os
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); stage = root / 'stage'; dest = root / 'dest'; stage.mkdir(); dest.mkdir()
            (stage / 'a').write_bytes(b'a'); (stage / 'b').write_bytes(b'b'); (dest / 'keep').write_bytes(b'keep')
            real_place = place_exclusive
            def link(source, target, **kwargs):
                if Path(source).name == 'b': raise OSError(28, 'test disk full')
                return real_place(source, target)
            with patch('huawei_runtime.place_exclusive', side_effect=link), self.assertRaises(OSError): publish_files(stage, dest)
            self.assertEqual([p.name for p in dest.iterdir()], ['keep'])


class RuntimeRecovery(unittest.IsolatedAsyncioTestCase):
    async def test_transient_discovery_failure_does_not_cancel_active_send(self):
        engine = Engine(); runtime = engine.huawei; stopped = []; ready = asyncio.Event()
        future = asyncio.get_running_loop().create_future()
        engine.session = {'id': 'active-send', 'protocol': 'huawei', 'direction': 'send'}
        engine.decisions = {'active-send': future}
        runtime.active = SimpleNamespace(stop=lambda: stopped.append(True))
        runtime.emit = lambda *args, **kwargs: None
        async def open_listener():
            runtime.listener = SimpleNamespace(stdout=None)
            runtime.port = 33651; runtime.identity = 'test'; ready.set()
        with patch('huawei_runtime.interfaces', side_effect=[subprocess.TimeoutExpired('ifconfig', 3), [LOCAL]]), patch.object(runtime, 'open_listener', side_effect=open_listener):
            task = asyncio.create_task(runtime.run())
            try:
                await asyncio.wait_for(ready.wait(), 3)
                self.assertEqual(stopped, [])
                self.assertFalse(future.done())
            finally:
                task.cancel(); await asyncio.gather(task, return_exceptions=True)

    async def test_persistent_discovery_failure_backs_off_and_coalesces_diagnostics(self):
        engine = Engine(); runtime = engine.huawei; events = []; delays = []
        runtime.emit = lambda event, **values: events.append((event, values))
        sleep = asyncio.sleep
        async def pause(seconds):
            delays.append(seconds)
            if len(delays) == 7: raise asyncio.CancelledError
            await sleep(0)
        with patch('huawei_runtime.interfaces', side_effect=OSError(24, 'temporary interface failure')), patch('huawei_runtime.asyncio.sleep', side_effect=pause):
            with self.assertRaises(asyncio.CancelledError): await runtime.run()
        self.assertEqual(delays, [1, 2, 4, 8, 16, 30, 30])
        self.assertEqual(sum(event == 'diagnostic' and value.get('detail') == 'huawei_runtime_stopped' for event, value in events), 1)

    async def test_huawei_cleanup_only_declines_its_own_pending_approval(self):
        engine = Engine(); loop = asyncio.get_running_loop()
        huawei = loop.create_future(); other = loop.create_future()
        engine.decisions = {'huawei-session': huawei, 'other-session': other}
        engine.session = {'id': 'other-session', 'protocol': 'mta'}
        engine.huawei.cancel()
        self.assertFalse(other.done())
        self.assertFalse(huawei.done())
        engine.session = {'id': 'huawei-session', 'protocol': 'huawei'}
        engine.huawei.cancel()
        self.assertFalse(huawei.result())
        self.assertFalse(other.done())

    async def test_transient_listener_failure_retries_and_closes_partial_listener(self):
        engine = Engine(); runtime = engine.huawei
        ready = asyncio.Event(); events = []; closed = []
        runtime.emit = lambda event, **values: events.append((event, values))
        attempts = 0
        async def open_listener():
            nonlocal attempts
            attempts += 1
            runtime.children = SimpleNamespace(close=lambda: closed.append(attempts))
            if attempts == 1:
                raise OSError(24, 'temporary listener failure')
            runtime.listener = SimpleNamespace(stdout=None)
            runtime.port = 33651; runtime.identity = 'test'
            ready.set()
        with patch('huawei_runtime.interfaces', return_value=[LOCAL]), patch.object(runtime, 'open_listener', side_effect=open_listener):
            task = asyncio.create_task(runtime.run())
            try:
                await asyncio.wait_for(ready.wait(), 3)
                self.assertFalse(task.done())
                self.assertEqual(attempts, 2)
                self.assertEqual(closed, [1])
                self.assertTrue(any(event == 'diagnostic' and value.get('detail') == 'huawei_runtime_stopped' for event, value in events))
                self.assertTrue(any(event == 'huawei_discovery' and value.get('enabled') for event, value in events))
            finally:
                task.cancel()
                await asyncio.gather(task, return_exceptions=True)

    async def test_transient_interface_timeout_does_not_permanently_stop_discovery(self):
        engine = Engine(); runtime = engine.huawei
        ready = asyncio.Event()
        runtime.emit = lambda *args, **kwargs: None
        async def open_listener():
            runtime.listener = SimpleNamespace(stdout=None)
            runtime.port = 33651; runtime.identity = 'test'
            ready.set()
        with patch('huawei_runtime.interfaces', side_effect=[subprocess.TimeoutExpired('ifconfig', 3), [LOCAL]]), patch.object(runtime, 'open_listener', side_effect=open_listener):
            task = asyncio.create_task(runtime.run())
            try:
                await asyncio.wait_for(ready.wait(), 3)
                self.assertFalse(task.done())
            finally:
                task.cancel()
                await asyncio.gather(task, return_exceptions=True)


class RuntimeShutdown(unittest.TestCase):
    def test_eof_and_sigterm_reap_owned_loopback_listener(self):
        sources = str(Path(__file__).resolve().parents[1] / 'Sources')
        code = '''import asyncio, ipaddress, sys
from types import SimpleNamespace
sys.path.insert(0, sys.argv[1])
import huawei_runtime
from engine import Engine
huawei_runtime.interfaces=lambda:[SimpleNamespace(interface='en0',address='127.0.0.1',network=ipaddress.ip_network('127.0.0.0/8'))]
from pathlib import Path
huawei_runtime.IDENTITY=Path(sys.argv[2])
asyncio.run(Engine().run())
'''
        identity = tempfile.TemporaryDirectory(); self.addCleanup(identity.cleanup)
        # host_gone: the native host died first, so every later engine write fails.
        for stop in ('eof', 'sigterm', 'host_gone'):
            with self.subTest(stop=stop):
                process = subprocess.Popen([sys.executable, '-u', '-c', code, sources, str(Path(identity.name) / 'id.pem')], stdin=subprocess.PIPE,
                                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
                try:
                    deadline, ready = time.monotonic() + 10, False
                    while time.monotonic() < deadline:
                        if select.select([process.stdout], [], [], .5)[0]:
                            value = json.loads(process.stdout.readline())
                            if value.get('event') == 'huawei_discovery' and value.get('enabled'):
                                ready = True; break
                    self.assertTrue(ready)
                    children = subprocess.run(['/usr/bin/pgrep', '-P', str(process.pid)], capture_output=True, text=True).stdout.split()
                    self.assertTrue(children)
                    if stop == 'host_gone': process.stdout.close(); process.stdin.close()
                    elif stop == 'eof': process.stdin.close()
                    else: process.terminate()
                    process.wait(timeout=6)
                    for child in children:
                        with self.assertRaises(ProcessLookupError): os.kill(int(child), 0)
                finally:
                    if process.poll() is None: process.kill(); process.wait()
                    if not process.stdin.closed: process.stdin.close()
                    if not process.stdout.closed: process.stdout.close()


if __name__ == '__main__': unittest.main()
