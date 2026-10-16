# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 anDrop contributors
"""Exercise the sender against a real TLS client and a deterministic BLE peer."""
import asyncio,io,json,ssl,sys,tempfile,time,unittest,zipfile
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'Sources'))
from aiohttp import ClientSession
from engine import Engine,Keys,wire,parse_wire,bu

class SendIntegrationTests(unittest.IsolatedAsyncioTestCase):
    async def transfer(self,ack_first=False,reject=False,wrong_peer=False,multiple=False):
        jobs=[];downloads=[];events=[];keys=Keys();callback=None;attempts=[]
        async def peer(host,port):
            context=ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT);context.check_hostname=False;context.verify_mode=ssl.CERT_NONE
            confirmed='192.168.99.2' if wrong_peer else '127.0.0.1'
            def ack():callback(None,json.dumps({'wlan':'wlan','wlan_accept':True,'ip':keys.encrypt(confirmed)}).encode())
            async with ClientSession() as client:
                if ack_first:ack();await asyncio.sleep(.02)
                async with client.ws_connect(f'https://{host}:{port}/websocket',ssl=context) as ws:
                    if not ack_first:ack()
                    async for m in ws:
                        if m.type.name!='TEXT':continue
                        kind,index,name,p=parse_wire(m.data)
                        if name in ('wlanBandwidth','versionNegotiation'):await ws.send_str(wire('ack',index,name,{}))
                        elif name=='sendRequest':
                            async with client.get(f'https://{host}:{port}/download',params={'taskId':p['id']},ssl=context) as response:
                                downloads.append(await response.read())
                            await ws.send_str(wire('action',10,'status',{'taskId':p['id'],'type':1}));break
        class BLE:
            is_connected=False
            def __init__(self,*a,**k):pass
            async def connect(self):self.is_connected=True
            async def disconnect(self):self.is_connected=False
            async def read_gatt_char(self,*a):return json.dumps({'state':0,'key':keys.public}).encode()
            async def start_notify(self,u,cb):
                nonlocal callback;callback=cb
            async def write_gatt_char(self,u,data,**kw):
                if data==b'cancel':return
                p=json.loads(data)
                if 'key' in p:
                    keys.derive(p['key']);callback(None,json.dumps({'wlan':'wlan','ip':keys.encrypt('192.168.49.1')}).encode())
                else:
                    host=keys.decrypt(p['ip']);port=int(keys.decrypt(p['port']));attempts.append(host)
                    if reject or (multiple and len(attempts)==1):callback(None,json.dumps({'wlan':'wlan','wlan_accept':False}).encode())
                    else:jobs.append(asyncio.create_task(peer(host,port)))
        with tempfile.TemporaryDirectory() as folder:
            paths=[]
            for name,data in [('日本語.txt',b'fixture'),('empty.bin',b'')]:
                path=Path(folder)/name;path.write_bytes(data);paths.append(str(path))
            engine=Engine();engine.discovering=True;engine.devices['peer']=SimpleNamespace(address='00000000-0000-0000-0000-000000000001');engine.peers['peer']={'name':'Fixture','last':time.monotonic()}
            addresses=['127.0.0.1','127.0.0.1'] if multiple else ['127.0.0.1']
            try:
                with patch('engine.BleakClient',BLE),patch('engine.lan_addresses',return_value=addresses),patch('engine.private_ipv4',side_effect=lambda x:x=='127.0.0.1' or x=='192.168.99.2'),patch('engine.emit',side_effect=lambda event,**kw:events.append({'event':event,**kw})):
                    await asyncio.wait_for(engine.send('peer',paths),5)
                terminals=[e for e in events if e.get('state') in ['complete','failed']]
                self.assertEqual(terminals[-1]['state'],'failed' if reject or wrong_peer else 'complete')
                self.assertEqual(len(downloads),0 if reject or wrong_peer else 1)
                self.assertIsNone(engine.session)
                if downloads:
                    with zipfile.ZipFile(io.BytesIO(downloads[0])) as z:
                        self.assertEqual(z.read('日本語.txt'),b'fixture');self.assertEqual(z.read('empty.bin'),b'')
                if multiple:self.assertEqual(len(attempts),2)
            finally:
                for job in jobs:job.cancel()
                await asyncio.gather(*jobs,return_exceptions=True)

    async def test_gatt_ack_before_tls_connection(self):await self.transfer(ack_first=True)
    async def test_tls_connection_before_gatt_ack(self):await self.transfer()
    async def test_peer_address_mismatch_cannot_download(self):await self.transfer(wrong_peer=True)
    async def test_wlan_rejection_does_not_offer_files(self):await self.transfer(reject=True)
    async def test_second_interface_after_explicit_rejection(self):await self.transfer(multiple=True)

    async def test_udp_failure_does_not_abort_working_control_channel(self):
        from unittest.mock import AsyncMock
        with patch('engine.retry_local_route',new=AsyncMock(side_effect=OSError('UDP unavailable'))):
            await self.transfer()
