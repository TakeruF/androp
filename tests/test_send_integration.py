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
    async def transfer(self,ack_first=False,reject=False,wrong_peer=False,multiple=False,declined=False,fixtures=None,expected_mime='file/*',binary_control=False):
        jobs=[];downloads=[];events=[];keys=Keys();callback=None;attempts=[];offers=[];content_types=[];initial_offers=[]
        if fixtures is None:fixtures=[('日本語.txt',b'fixture'),('empty.bin',b'')]
        async def peer(host,port):
            context=ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT);context.check_hostname=False;context.verify_mode=ssl.CERT_NONE
            confirmed='192.168.99.2' if wrong_peer else '127.0.0.1'
            def ack():callback(None,json.dumps({'wlan':'wlan','wlan_accept':True,'ip':keys.encrypt(confirmed)}).encode())
            async with ClientSession() as client:
                if ack_first:ack();await asyncio.sleep(.02)
                async with client.ws_connect(f'https://{host}:{port}/websocket',ssl=context) as ws:
                    async def control(value):
                        if binary_control:await ws.send_bytes(value.encode('utf-8'))
                        else:await ws.send_str(value)
                    if not ack_first:ack()
                    async for m in ws:
                        if m.type.name!='TEXT':continue
                        kind,index,name,p=parse_wire(m.data)
                        if name in ('wlanBandwidth','versionNegotiation'):await control(wire('ack',index,name,{}))
                        elif name=='sendRequest':
                            offers.append(p)
                            async with client.get(f'https://{host}:{port}/download',params={'taskId':p['id']},ssl=context) as response:
                                content_types.append(response.headers['Content-Type'])
                                downloads.append(await response.read())
                            await control(wire('action',10,'status',{'taskId':p['id'],'type':1}));break
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
                    keys.derive(p['key'])
                    initial_offers.append({'type':keys.decrypt(p['type']),'number':keys.decrypt(p['number'])})
                    if declined:
                        callback(None,b'3');return
                    callback(None,json.dumps({'wlan':'wlan','ip':keys.encrypt('192.168.49.1')}).encode())
                else:
                    host=keys.decrypt(p['ip']);port=int(keys.decrypt(p['port']));attempts.append(host)
                    if reject or (multiple and len(attempts)==1):callback(None,json.dumps({'wlan':'wlan','wlan_accept':False}).encode())
                    else:jobs.append(asyncio.create_task(peer(host,port)))
        with tempfile.TemporaryDirectory() as folder:
            paths=[]
            for name,data in fixtures:
                path=Path(folder)/name;path.write_bytes(data);paths.append(str(path))
            engine=Engine();engine.discovering=True;engine.devices['peer']=SimpleNamespace(address='00000000-0000-0000-0000-000000000001');engine.peers['peer']={'name':'Fixture','last':time.monotonic()}
            addresses=['127.0.0.1','127.0.0.1'] if multiple else ['127.0.0.1']
            try:
                with patch('engine.BleakClient',BLE),patch('engine.lan_addresses',return_value=addresses),patch('engine.private_ipv4',side_effect=lambda x:x=='127.0.0.1' or x=='192.168.99.2'),patch('engine.emit',side_effect=lambda event,**kw:events.append({'event':event,**kw})):
                    await asyncio.wait_for(engine.send('peer',paths),5)
                terminals=[e for e in events if e.get('state') in ['complete','failed','declined']]
                self.assertEqual(terminals[-1]['state'],'declined' if declined else 'failed' if reject or wrong_peer else 'complete')
                self.assertEqual(len(downloads),0 if declined or reject or wrong_peer else 1)
                if declined:
                    self.assertEqual(len(terminals),1)
                    self.assertEqual(attempts,[])
                self.assertIsNone(engine.session)
                self.assertEqual(initial_offers,[{'type':expected_mime,'number':str(len(fixtures))}])
                if downloads:
                    self.assertEqual(offers[0]['mimeType'],expected_mime)
                    self.assertEqual(offers[0]['fileName'],fixtures[0][0])
                    self.assertEqual(offers[0]['fileCount'],len(fixtures))
                    self.assertEqual(offers[0]['totalSize'],sum(len(data) for _,data in fixtures))
                    self.assertEqual(content_types,['application/zip'])
                    with zipfile.ZipFile(io.BytesIO(downloads[0])) as z:
                        self.assertEqual(z.namelist(),[name for name,_ in fixtures])
                        for name,data in fixtures:self.assertEqual(z.read(name),data)
                if multiple:self.assertEqual(len(attempts),2)
            finally:
                for job in jobs:job.cancel()
                await asyncio.gather(*jobs,return_exceptions=True)

    async def test_gatt_ack_before_tls_connection(self):await self.transfer(ack_first=True)
    async def test_tls_connection_before_gatt_ack(self):await self.transfer()
    async def test_peer_address_mismatch_cannot_download(self):await self.transfer(wrong_peer=True)
    async def test_wlan_rejection_does_not_offer_files(self):await self.transfer(reject=True)
    async def test_recipient_decline_is_distinct_from_transfer_failure(self):await self.transfer(declined=True)
    async def test_second_interface_after_explicit_rejection(self):await self.transfer(multiple=True)
    async def test_utf8_binary_control_frames_complete_over_tls(self):await self.transfer(binary_control=True)
    async def test_typed_offers_preserve_zip_transport_and_contents(self):
        for fixtures,mime in [
            ([('書類.PDF',b'%PDF-1.4\nfixture')],'application/pdf'),
            ([('photo.jpg',b'jpeg fixture')],'image/jpeg'),
            ([('a.jpg',b'jpeg fixture'),('b.png',b'png fixture')],'image/*'),
            ([('a.jpg',b'jpeg fixture'),('b.pdf',b'%PDF fixture')],'file/*'),
        ]:
            with self.subTest(mime=mime):
                await self.transfer(fixtures=fixtures,expected_mime=mime)

    async def test_pdf_type_reaches_approval_even_when_recipient_declines(self):
        await self.transfer(fixtures=[('document.pdf',b'%PDF fixture')],expected_mime='application/pdf',declined=True)

    async def test_udp_failure_does_not_abort_working_control_channel(self):
        from unittest.mock import AsyncMock
        with patch('engine.retry_local_route',new=AsyncMock(side_effect=OSError('UDP unavailable'))):
            await self.transfer()

    async def test_url_and_text_commands_are_rejected_without_starting_transfer(self):
        from unittest.mock import AsyncMock
        engine=Engine()
        for field in ('link','text'):
            with patch.object(engine,'send',new_callable=AsyncMock) as send, patch('engine.emit') as emit:
                await engine.command({'command':'send','peer':'peer','paths':['fixture.txt'],field:'https://example.invalid/'})
                send.assert_not_awaited()
                self.assertEqual(emit.call_args.args,('error',))
                self.assertNotIn('example.invalid',emit.call_args.kwargs['detail'])
