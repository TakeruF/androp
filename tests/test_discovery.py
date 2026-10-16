# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 anDrop contributors

import asyncio, inspect, sys, tempfile, unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock, Mock, patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Sources'))
from engine import Engine, PEER_TTL, bu

ID = 'mta11:112233445566'
DEVICE = SimpleNamespace(address='test-endpoint')
def advertisement(role='r'):
    return SimpleNamespace(service_data={bu('3333'): f'112233445566-{role}--1-11-9'.encode(), bu('3334'): b'Test device'}, local_name=None)

class DiscoveryTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.engine=Engine(); self.engine.discovering=True
        self.clock=Mock(return_value=100)
        patch('engine.time',SimpleNamespace(monotonic=self.clock)).start()
        self.events=patch('engine.emit').start()
        self.addCleanup(patch.stopall)
        self.engine.discovered(DEVICE,advertisement())

    def test_callback_matches_bleak_contract_and_cannot_cross_scan_sessions(self):
        old=object();new=object()
        callback=self.engine.discovery_callback(old)
        self.assertEqual(len(inspect.signature(callback).parameters),2)
        self.engine.clear_peers();self.engine.scan_token=new
        callback(DEVICE,advertisement())
        self.assertEqual(self.engine.peers,{})
        self.engine.discovery_callback(new)(DEVICE,advertisement())
        self.assertIn(ID,self.engine.peers)

    def test_expiry_removes_display_and_connection_route_at_boundary(self):
        self.clock.return_value=100+PEER_TTL-0.01
        self.engine.publish_peers()
        self.assertEqual(len(self.events.call_args.kwargs['peers']),1)
        self.clock.return_value=100+PEER_TTL
        self.engine.publish_peers()
        self.assertEqual(self.events.call_args.kwargs['peers'],[])
        self.assertEqual(self.engine.devices,{})

    def test_publishing_does_not_extend_lifetime_but_new_advertisement_does(self):
        self.clock.return_value=109;self.engine.publish_peers()
        self.assertEqual(self.engine.peers[ID]['last'],100)
        self.engine.discovered(DEVICE,advertisement())
        self.clock.return_value=115;self.engine.publish_peers()
        self.assertIn(ID,self.engine.peers)
        self.clock.return_value=119;self.engine.publish_peers()
        self.assertEqual(self.engine.peers,{})

    def test_partial_packets_do_not_refresh_or_prematurely_revoke(self):
        self.clock.return_value=105
        self.engine.discovered(DEVICE,SimpleNamespace(service_data={},local_name=None))
        self.assertEqual(self.engine.peers[ID]['last'],100)

    def test_sender_only_advertisement_revokes_receiver_immediately(self):
        self.engine.discovered(DEVICE,advertisement('s'))
        self.assertEqual(self.engine.peers,{})
        self.assertEqual(self.events.call_args.kwargs['peers'],[])

    def test_old_endpoint_cannot_revoke_new_route(self):
        replacement=SimpleNamespace(address='rotated-endpoint')
        self.engine.discovered(replacement,advertisement())
        self.engine.discovered(DEVICE,advertisement('s'))
        self.assertIs(self.engine.devices[ID],replacement)

    async def test_closing_chooser_clears_and_ignores_late_callbacks(self):
        await self.engine.command({'command':'scan','value':False})
        self.engine.discovered(DEVICE,advertisement())
        self.assertEqual(self.engine.peers,{})
        self.assertEqual(self.engine.devices,{})
        await self.engine.command({'command':'scan','value':True})
        self.assertEqual(self.engine.peers,{})

    async def test_switching_off_clears_and_ignores_callbacks(self):
        await self.engine.command({'command':'enabled','value':False})
        self.engine.discovered(DEVICE,advertisement())
        self.assertEqual(self.engine.peers,{})

    async def test_stale_send_does_not_connect_or_prepare(self):
        self.clock.return_value=100+PEER_TTL
        with patch('engine.BleakClient') as client:
            await self.engine.send(ID,['unused-file'])
        client.assert_not_called()
        self.assertIsNone(self.engine.session)
        self.assertEqual(self.events.call_args.args,('transfer',))
        self.assertEqual(self.events.call_args.kwargs['state'],'failed')

    async def test_send_keeps_selected_route_when_chooser_closes_during_preparation(self):
        async def close_during_open(operation,*args):
            await self.engine.command({'command':'scan','value':False})
            return operation(*args)
        with tempfile.TemporaryDirectory() as folder:
            file=Path(folder)/'example.txt';file.write_text('test')
            with patch('engine.asyncio.to_thread',side_effect=close_during_open), patch('engine.BleakClient',side_effect=RuntimeError('stop before any real connection')) as client:
                await self.engine.send(ID,[str(file)])
        client.assert_called_once_with(DEVICE,timeout=15)
        self.assertIsNone(self.engine.session)
        self.assertEqual(self.engine.devices,{})

    async def test_scan_failure_clears_before_backoff_and_ignores_late_callbacks(self):
        engine=self.engine
        class Scanner:
            def __init__(self,**options): self.callback=options['detection_callback']
            async def __aenter__(self):
                self.callback(DEVICE,advertisement());return self
            async def __aexit__(self,*args): self.callback(DEVICE,advertisement())
        calls=0
        async def sleep(_):
            nonlocal calls
            calls+=1
            if calls==1:raise RuntimeError('scanner interrupted')
            self.assertEqual(engine.peers,{})
            self.assertEqual(engine.devices,{})
            raise asyncio.CancelledError()
        with patch('engine.BleakScanner',Scanner),patch('engine.asyncio.sleep',side_effect=sleep):
            with self.assertRaises(asyncio.CancelledError):await engine.scanning()
        self.assertIsNone(engine.scanner)

    async def test_scanner_start_failure_does_not_keep_old_results(self):
        scanner=AsyncMock();scanner.__aenter__.side_effect=RuntimeError('unavailable')
        async def sleep(_):
            self.assertEqual(self.engine.peers,{})
            raise asyncio.CancelledError()
        with patch('engine.BleakScanner',return_value=scanner),patch('engine.asyncio.sleep',side_effect=sleep):
            with self.assertRaises(asyncio.CancelledError):await self.engine.scanning()

if __name__=='__main__':unittest.main()
