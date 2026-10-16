# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 anDrop contributors
import base64,json,sys,unittest
from pathlib import Path
from unittest.mock import AsyncMock,Mock,patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'Sources'))
from engine import Engine,Keys

class NetworkOfferTests(unittest.IsolatedAsyncioTestCase):
    async def check_offer(self,kind):
        engine=Engine();keys=Keys();peer=Keys();keys.derive(peer.public)
        s={'id':'session','direction':'receive','state':'verifying','central':'central','keys':keys,'network_hint':'192.168.5.2'};engine.session=s
        p={'port':keys.encrypt('9000')}
        if kind=='reuse':p['reuse']=keys.encrypt('true')
        else:p['ip']=keys.encrypt('192.168.5.2')
        if kind=='lan':p['wlan']='wlan'
        if kind=='direct':p.update(ssid=keys.encrypt('test-direct'),psk=keys.encrypt('test-fixture-password'))
        obj={'uuid':'9896','central':'central','data':base64.b64encode(json.dumps(p).encode()).decode()}
        sock=Mock();receive=AsyncMock();tasks=[]
        def launch(coro):
            import asyncio
            task=asyncio.create_task(coro);tasks.append(task);return task
        with patch('engine.local_endpoint',return_value='192.168.5.1'),patch('engine.interface_for_address',return_value='en0'),patch('engine.bind_interface'),patch('engine.socket.socket',return_value=sock),patch.object(engine,'receive',receive),patch.object(engine,'launch',side_effect=launch),patch('engine.emit') as events:
            await engine.receive_write(obj)
            for task in tasks:await task
        receive.assert_awaited_once_with(s,'192.168.5.2',9000,sock)
        notifications=[x.kwargs for x in events.call_args_list if x.args[0]=='ble_notify']
        self.assertEqual(len(notifications),int(kind=='lan'))
    async def test_standard_lan_offer(self):await self.check_offer('lan')
    async def test_already_reachable_direct_offer_is_not_immediately_cancelled(self):await self.check_offer('direct')
    async def test_reuse_endpoint_is_limited_to_this_ble_sessions_hint(self):await self.check_offer('reuse')
