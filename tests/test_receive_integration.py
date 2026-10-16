# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 anDrop contributors
"""Actual TLS/WebSocket/HTTP transfers; only the BLE transport is substituted."""
import asyncio,datetime,hashlib,io,json,socket,ssl,sys,tempfile,unittest,uuid,zipfile
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'Sources'))
from aiohttp import web
from cryptography import x509
from cryptography.x509.oid import NameOID
from cryptography.hazmat.primitives import hashes,serialization
from cryptography.hazmat.primitives.asymmetric import ec
from engine import Engine,wire,parse_wire,sender_identifier

class ReceiveIntegrationTests(unittest.IsolatedAsyncioTestCase):
    async def transfer(self,*,trusted=False,sender='test-sender-unique-device',allowed=True,decision=True,revoked=False,disabled=False,files=None,malformed_count=False,udp_probes=True,cancel_midstream=False):
        files=files or {'日本語.txt':b'synthetic file\n','empty.bin':b''}
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);destination=root/'received';destination.mkdir()
            key=ec.generate_private_key(ec.SECP256R1());subject=x509.Name([x509.NameAttribute(NameOID.COMMON_NAME,'anDrop test')]);now=datetime.datetime.now(datetime.timezone.utc)
            cert=x509.CertificateBuilder().subject_name(subject).issuer_name(subject).public_key(key.public_key()).serial_number(x509.random_serial_number()).not_valid_before(now-datetime.timedelta(minutes=1)).not_valid_after(now+datetime.timedelta(days=1)).sign(key,hashes.SHA256())
            (root/'cert').write_bytes(cert.public_bytes(serialization.Encoding.PEM));(root/'key').write_bytes(key.private_bytes(serialization.Encoding.PEM,serialization.PrivateFormat.PKCS8,serialization.NoEncryption()))
            tls=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);tls.load_cert_chain(root/'cert',root/'key')
            zipped=io.BytesIO()
            with zipfile.ZipFile(zipped,'w') as z:
                for name,data in files.items():z.writestr(name,data)
            engine=Engine();engine.destination=str(destination);engine.trusted_only=trusted
            engine.trusted_ids={sender_identifier('test-sender-unique-device')} if allowed else {sender_identifier('another-device-id')}
            session={'id':uuid.uuid4().hex,'direction':'receive','central':str(uuid.uuid4()).upper(),'count':len(files),'peer':'Same account name'};engine.session=session
            downloads=[];events=[];udp=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);udp.bind(('127.0.0.1',0));udp.setblocking(False);udp_port=udp.getsockname()[1]
            async def websocket(request):
                ws=web.WebSocketResponse();await ws.prepare(request)
                with socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as out:
                    for _ in range(64 if udp_probes else 0):out.sendto(bytes(4096),('127.0.0.1',udp_port));await asyncio.sleep(.001)
                await ws.receive_str()
                await ws.send_str(wire('action',1,'versionNegotiation',{}));await ws.receive_str()
                await ws.send_str(wire('action',2,'sendRequest',{'id':'task-fixture','senderId':sender,'senderName':'Same account name','fileCount':len(files)+(1 if malformed_count else 0),'totalSize':sum(map(len,files.values())),'fileName':next(iter(files))}))
                async for msg in ws:
                    if msg.type==web.WSMsgType.TEXT:
                        kind,index,name,p=parse_wire(msg.data)
                        if name=='status':await ws.send_str(wire('ack',index,name));break
                return ws
            async def download(request):
                downloads.append(request.query.get('taskId'));return web.Response(body=zipped.getvalue(),content_type='application/zip')
            app=web.Application();app.router.add_get('/websocket',websocket);app.router.add_get('/download',download)
            runner=web.AppRunner(app);await runner.setup();site=web.TCPSite(runner,'127.0.0.1',0,ssl_context=tls);await site.start();port=site._server.sockets[0].getsockname()[1]
            async def accept():
                for _ in range(1000):
                    if engine.decisions:
                        if revoked:engine.trusted_ids.clear()
                        if disabled:engine.scan_enabled=False
                        next(iter(engine.decisions.values())).set_result(decision);return
                    await asyncio.sleep(.01)
            approval=asyncio.create_task(accept())
            def observe(event,**values):
                events.append({'event':event,**values})
                if cancel_midstream and values.get('state')=='transferring' and values.get('completed',0)>0:
                    asyncio.current_task().cancel()
            try:
                with patch('engine.emit',side_effect=observe):
                    await asyncio.wait_for(engine.receive(session,'127.0.0.1',port,udp),8)
                should_succeed=(not trusted or (allowed and sender=='test-sender-unique-device' and not revoked)) and decision and not disabled and not malformed_count
                if cancel_midstream:
                    self.assertEqual(session['state'],'cancelled')
                    self.assertEqual(list(destination.iterdir()),[])
                    self.assertIsNone(engine.session)
                    self.assertFalse(engine.decisions)
                    self.assertEqual(len(downloads),1)
                    return events
                self.assertEqual(session['state'],'complete' if should_succeed else ('failed' if malformed_count else 'declined'))
                self.assertEqual(len(downloads),int(should_succeed),'Unauthorized or declined transfer must never fetch file bytes')
                self.assertIsNone(engine.session);self.assertFalse(engine.decisions)
                self.assertEqual(sorted(x.name for x in destination.iterdir()),sorted(files) if should_succeed else [])
                if should_succeed:
                    for name,data in files.items():self.assertEqual(hashlib.sha256((destination/name).read_bytes()).digest(),hashlib.sha256(data).digest())
                    self.assertEqual(session.get('device_identifier'),sender_identifier(sender))
                return events
            finally:
                approval.cancel();await asyncio.gather(approval,return_exceptions=True);await runner.cleanup()

    async def test_everyone_multiple_unicode_and_empty_files(self):await self.transfer()
    async def test_trusted_sender_with_new_bluetooth_address(self):await self.transfer(trusted=True)
    async def test_same_name_untrusted_sender_never_downloads(self):await self.transfer(trusted=True,allowed=False)
    async def test_changed_protocol_id_does_not_inherit_trust(self):await self.transfer(trusted=True,sender='different-device-id')
    async def test_missing_protocol_id_does_not_inherit_trust(self):await self.transfer(trusted=True,sender=None)
    async def test_user_decline_never_downloads(self):await self.transfer(decision=False)
    async def test_revocation_while_prompt_is_open_never_downloads(self):await self.transfer(trusted=True,revoked=True)
    async def test_disable_while_prompt_is_open_never_downloads(self):await self.transfer(disabled=True)
    async def test_invalid_file_count_never_downloads(self):await self.transfer(malformed_count=True)
    async def test_large_binary_content_and_progress(self):
        events=await self.transfer(files={'large.bin':bytes(range(256))*32768})
        progress=[x for x in events if x.get('state')=='transferring']
        self.assertGreaterEqual(len(progress),2)
        self.assertTrue(all(0<=x.get('completed',0)<=x.get('total',0) for x in progress))
    async def test_repeated_connections_do_not_share_authorization(self):
        for allowed in [True,False,True,False]:await self.transfer(trusted=True,allowed=allowed)

    async def test_blocked_udp_does_not_break_working_tls_transfer(self):await self.transfer(udp_probes=False)

    async def test_cancel_mid_download_cleans_partial_files(self):
        await self.transfer(files={'cancel.bin':bytes(range(256))*32768},cancel_midstream=True)
