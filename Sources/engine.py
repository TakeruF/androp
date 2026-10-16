# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 anDrop contributors

"""anDrop local interoperability engine. JSON-lines IPC with its native host.
No cloud, saved peer credentials, or USB transport. One transfer at a time.
"""
import asyncio, base64, datetime, errno, hashlib, ipaddress, json, os, shutil, socket, ssl, stat, sys, tempfile, time, uuid, zipfile
from pathlib import Path, PurePosixPath
from peer_metadata import parse_peer_metadata, peer_identifier
from aiohttp import web, ClientSession, ClientTimeout, Fingerprint, WSMsgType
from bleak import BleakClient, BleakScanner
from cryptography import x509
from cryptography.x509.oid import NameOID
from cryptography.hazmat.primitives import serialization, hashes, padding
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

LANG = 'en'
def t(en,zh): return zh if LANG=='zh' else en

UUID_BASE = '-0000-1000-8000-00805f9b34fb'
def bu(short): return '0000' + short + UUID_BASE
def emit(event, **payload):
    print(json.dumps({'event':event, **payload}, ensure_ascii=False, separators=(',',':')), flush=True)
def wire(kind, index, name, payload=None):
    return f'{kind}:{index}:{name}' + ('?' + json.dumps(payload,separators=(',',':')) if payload is not None else '')
def parse_wire(raw):
    if not isinstance(raw,str) or len(raw)>131072: raise ValueError('Invalid protocol message')
    head, sep, body = raw.partition('?'); kind,index,name = head.split(':',2)
    if kind not in ('action','ack') or not index.isdecimal(): raise ValueError('Invalid message type')
    obj=json.loads(body) if sep and body else {}
    if not isinstance(obj,dict): raise ValueError('Invalid message payload')
    return kind,int(index),name,obj

class Keys:
    def __init__(self): self.private=ec.generate_private_key(ec.SECP256R1()); self.key=None
    @property
    def public(self):
        return base64.b64encode(self.private.public_key().public_bytes(serialization.Encoding.DER,serialization.PublicFormat.SubjectPublicKeyInfo)).decode()
    def derive(self, peer):
        if len(peer)>1024: raise ValueError('Invalid key')
        public=serialization.load_der_public_key(base64.b64decode(peer,validate=True))
        if not isinstance(public,ec.EllipticCurvePublicKey) or public.curve.name!='secp256r1': raise ValueError('Unsupported key')
        self.key=base64.b64encode(self.private.exchange(ec.ECDH(),public))[:16]
    def encrypt(self, text):
        pad=padding.PKCS7(128).padder();data=pad.update(text.encode())+pad.finalize()
        c=Cipher(algorithms.AES(self.key),modes.CBC(b'0102030405060708')).encryptor()
        return base64.b64encode(c.update(data)+c.finalize()).decode()
    def decrypt(self, value):
        if not isinstance(value,str) or len(value)>65536: raise ValueError('Invalid encrypted value')
        c=Cipher(algorithms.AES(self.key),modes.CBC(b'0102030405060708')).decryptor();data=c.update(base64.b64decode(value))+c.finalize()
        p=padding.PKCS7(128).unpadder();return (p.update(data)+p.finalize()).decode()

def local_endpoint(host, port):
    ip=ipaddress.ip_address(host)
    if not ip.is_private or ip.is_loopback or ip.is_multicast or ip.is_unspecified or ip.version!=4 or not 1<=port<65535:
        raise ValueError('Invalid local endpoint')
    with socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as s:
        s.connect((host,port));return s.getsockname()[0]

async def retry_local_route(operation):
    # macOS can briefly return EHOSTUNREACH while refreshing an already-approved
    # app's local-network permission after an update. Retry with a new socket;
    # persistent denial and all other errors still fail normally.
    delays=(.2,.4,.8)
    for attempt in range(len(delays)+1):
        try:return await operation()
        except OSError as error:
            if error.errno!=errno.EHOSTUNREACH or attempt==len(delays):raise
            await asyncio.sleep(delays[attempt])

def safe_name(raw):
    # Never honor a network-provided path or create a symlink.
    name=raw.replace('\\','/'); p=PurePosixPath(name)
    if not name or p.is_absolute() or any(x in ('','..','.') for x in name.split('/')) or '\x00' in name:
        raise ValueError('Unsafe archive path')
    name=p.name
    if any(ord(c)<32 or c in ':/' for c in name) or len(name.encode())>240:
        raise ValueError('Unsupported file name')
    return name

def validate_archive(archive, expected_count, expected_size):
    entries=[x for x in archive.infolist() if not x.is_dir()]
    if not 1<=expected_count<=10000 or len(entries)!=expected_count: raise ValueError('File count mismatch')
    if sum(x.file_size for x in entries)!=expected_size: raise ValueError('File size mismatch')
    for entry in archive.infolist():
        safe_name(entry.filename.rstrip('/'))
        mode=entry.external_attr>>16
        if stat.S_ISLNK(mode) or (stat.S_IFMT(mode) not in (0,stat.S_IFREG,stat.S_IFDIR)) or entry.flag_bits&1:
            raise ValueError('Unsupported archive entry')
    return entries

async def unpack(archive_path, destination, count, total, progress):
    destination=Path(destination).resolve(strict=True)
    if not destination.is_dir(): raise ValueError('Save folder is unavailable')
    if shutil.disk_usage(destination).free < total+16*1024*1024: raise ValueError(t('Not enough free disk space.','磁盘空间不足。'))
    saved=[]; written=0
    # Place complete files by an exclusive hard link; never replace an existing file.
    try:
        with zipfile.ZipFile(archive_path) as archive:
            entries=validate_archive(archive,count,total)
            for entry in entries:
                name=safe_name(entry.filename)
                fd,tmp=tempfile.mkstemp(prefix='.anDrop-',dir=destination)
                try:
                    with os.fdopen(fd,'wb') as out, archive.open(entry) as src:
                        digest=hashlib.sha256(); n=0
                        while chunk:=src.read(1024*1024):
                            out.write(chunk);digest.update(chunk);n+=len(chunk);written+=len(chunk)
                            if n>entry.file_size or written>total: raise ValueError('Unexpected file size')
                            progress(written,total);await asyncio.sleep(0)
                        out.flush();os.fsync(out.fileno())
                    if n!=entry.file_size: raise ValueError('Incomplete file')
                    # Mark downloaded content; opening remains an explicit user action.
                    import ctypes
                    libc=ctypes.CDLL(None)
                    attribute=f'0083;{int(time.time()):x};anDrop;'.encode()
                    setter=libc.setxattr
                    setter.argtypes=[ctypes.c_char_p,ctypes.c_char_p,ctypes.c_void_p,ctypes.c_size_t,ctypes.c_uint32,ctypes.c_int]
                    setter(os.fsencode(tmp),b'com.apple.quarantine',attribute,len(attribute),0,0)
                    for attempt in range(10000):
                        stem=Path(name).stem;suffix=Path(name).suffix
                        final=destination/(name if not attempt else f'{stem} ({attempt}){suffix}')
                        try: os.link(tmp,final);break
                        except FileExistsError: continue
                    else: raise ValueError(t('Too many files with the same name.','同名文件过多。'))
                    saved.append({'path':str(final),'bytes':n,'sha256':digest.hexdigest()})
                finally:
                    try: os.unlink(tmp)
                    except FileNotFoundError: pass
        return saved
    except BaseException:
        for item in saved:
            try: Path(item['path']).unlink()
            except FileNotFoundError: pass
        raise

class Engine:
    def __init__(self):
        self.destination=str(Path.home()/'Downloads');self.name='anDrop Mac';self.keys=Keys();self.session=None
        self.scanner=None;self.devices={};self.peers={};self.last_peers=0;self.decisions={};self.scan_enabled=True;self.discovering=False;self.jobs=set()
    def launch(self,coro):
        task=asyncio.create_task(coro);self.jobs.add(task);task.add_done_callback(self.jobs.discard);return task
    def read_state(self):
        emit('ble_read',uuid='9898',value={'state':1 if self.session else 0,'key':self.keys.public,'version':'10014','isFast':0,'pv':4})
    def notify(self,value,central=None):
        data=value if isinstance(value,str) else json.dumps(value,separators=(',',':'))
        emit('ble_notify',uuid='9895',data=base64.b64encode(data.encode()).decode(),central=central)
    def update(self,session,state,**kwargs):
        session['state']=state
        emit('transfer',id=session['id'],direction=session['direction'],peer=session.get('peer','Android'),state=state,**kwargs)
    def progress(self,s,n,total):
        now=time.monotonic()
        if now-s.get('last_progress',0)>.2 or n>=total:
            s['last_progress']=now;self.update(s,'transferring',completed=n,total=total)
    async def reset(self,s):
        if self.session is s:
            self.session=None;self.keys=Keys();self.read_state()
    async def receive_write(self,obj):
        central=obj.get('central','')
        if obj.get('uuid')!='9896': return
        raw=base64.b64decode(obj.get('data',''))
        if len(raw)>65536: return
        payload=json.loads(raw)
        if not isinstance(payload,dict): return
        if 'key' in payload:
            if not self.scan_enabled: self.notify('3',central);return
            if self.session: self.notify('3',central);return
            keys=self.keys;keys.derive(payload['key']);count=int(keys.decrypt(payload['number']))
            if not 1<=count<=10000: self.notify('3',central);return
            s={'id':uuid.uuid4().hex,'direction':'receive','peer':keys.decrypt(payload.get('device_name',''))[:100] or 'Android','central':central,'keys':keys,'count':count}
            self.session=s;self.read_state();future=asyncio.get_running_loop().create_future();self.decisions[s['id']]=future
            self.update(s,'request',count=count,name=t(f'{count} files',f'{count} 个文件'))
            try: accepted=await asyncio.wait_for(future,28)
            except TimeoutError: accepted=False
            finally: self.decisions.pop(s['id'],None)
            if self.session is not s:return
            if accepted:
                self.update(s,'connecting');self.notify('6',central)
                async def expire():
                    await asyncio.sleep(15)
                    if self.session is s and s.get('state')=='connecting':
                        self.notify('cancel',central);self.update(s,'failed',detail=t('Use the same Wi-Fi and try again.','请连接同一 Wi-Fi 后重试。'));await self.reset(s)
                self.launch(expire())
            else:
                self.notify('3',central);self.update(s,'declined');await self.reset(s)
        elif self.session and self.session.get('central')==central:
            s=self.session;k=s['keys']
            if 'wlan' in payload and 'port' in payload and 'task' not in s:
                host=k.decrypt(payload['ip']);port=int(k.decrypt(payload['port']));local=local_endpoint(host,port)
                udp=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);udp.bind((local,port+1));udp.setblocking(False)
                self.notify({'wlan':'wlan','wlan_accept':True,'ip':k.encrypt(local)},central)
                s['task']=self.launch(self.receive(s,host,port,udp))
            elif 'ssid' in payload:
                self.notify('cancel',central);self.update(s,'failed',detail=t('Connect this Mac and your phone to the same Wi-Fi.','请将 Mac 和手机连接到同一 Wi-Fi。'));await self.reset(s)
    async def receive(self,s,host,port,udp):
        async def bandwidth():
            total=0;start=None;loop=asyncio.get_running_loop()
            while total<262144:
                packet,addr=await loop.sock_recvfrom(udp,4096)
                if addr[0]!=host:continue
                start=start or time.monotonic();total+=len(packet)
            return total/1048576/max(time.monotonic()-start,.001)
        bw=asyncio.create_task(bandwidth());ws=None;taskid=''
        try:
            self.update(s,'connecting')
            context=ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT);context.check_hostname=False;context.verify_mode=ssl.CERT_NONE
            timeout=ClientTimeout(total=None,sock_connect=8,sock_read=35)
            async with ClientSession(timeout=timeout,trust_env=False) as client:
                async with await retry_local_route(lambda: client.ws_connect(f'https://{host}:{port}/websocket',ssl=context,max_msg_size=131072)) as ws:
                    connection=ws._response.connection
                    sslobject=connection.transport.get_extra_info('ssl_object')
                    fingerprint=hashlib.sha256(sslobject.getpeercert(binary_form=True)).digest()
                    speed=await asyncio.wait_for(bw,2)
                    await ws.send_str(wire('ack',0,'wlanBandwidth',{'speed':f'{speed:.2f}'}))
                    async with asyncio.timeout(45):
                        while True:
                            raw=await ws.receive_str();kind,index,name,p=parse_wire(raw)
                            if kind!='action':continue
                            if name=='wlanBandwidth':await ws.send_str(wire('ack',index,name,{'speed':f'{speed:.2f}'}))
                            elif name=='versionNegotiation':await ws.send_str(wire('ack',index,name,{'version':1,'threadLimit':1}))
                            elif name=='sendRequest':break
                            else:await ws.send_str(wire('ack',index,name))
                    count=int(p.get('fileCount',0));size=int(p.get('totalSize',-1));taskid=str(p.get('id',''))
                    if count!=s['count'] or size<0 or len(taskid)>256 or not taskid:raise ValueError('Invalid transfer metadata')
                    if shutil.disk_usage(self.destination).free<size*2+16*1024*1024:raise ValueError(t('Not enough free disk space.','磁盘空间不足。'))
                    await ws.send_str(wire('ack',index,name));self.update(s,'transferring',name=str(p.get('fileName',t('Files','文件')))[:240],count=count,total=size,completed=0)
                    with tempfile.TemporaryDirectory(prefix='anDrop-',dir=self.destination) as td:
                        archive=Path(td)/'incoming.zip';limit=size+max(1048576,count*65536);downloaded=0
                        async with client.get(f'https://{host}:{port}/download',params={'taskId':taskid},ssl=Fingerprint(fingerprint)) as response:
                            if response.status!=200:raise ValueError(t('Could not download files from the phone.','无法从手机获取文件。'))
                            with archive.open('wb') as out:
                                async for chunk in response.content.iter_chunked(1024*1024):
                                    downloaded+=len(chunk)
                                    if downloaded>limit:raise ValueError('Transfer exceeds declared size')
                                    out.write(chunk);self.progress(s,min(downloaded,size),size)
                        saved=await unpack(archive,self.destination,count,size,lambda n,t:self.progress(s,n,t))
                    await ws.send_str(wire('action',100,'status',{'taskId':taskid,'id':taskid,'type':1,'reason':'ok'}))
                    try:await asyncio.wait_for(ws.receive(),2)
                    except TimeoutError:pass
                    self.update(s,'complete',files=saved,count=count,total=size,completed=size)
        except asyncio.CancelledError:
            if ws and not ws.closed:
                await ws.send_str(wire('action',101,'status',{'taskId':taskid,'type':3,'reason':'user interrupt'}))
            self.notify('cancel',s['central']);self.update(s,'cancelled')
        except Exception as e:
            self.notify('cancel',s['central']);self.update(s,'failed',detail=t(f'Receive failed: {e or type(e).__name__}',f'接收失败：{e or type(e).__name__}'))
        finally:
            bw.cancel();udp.close();await self.reset(s)
    def discovered(self,device,ad):
        if bu('3333') not in ad.service_data:return
        identity=ad.service_data[bu('3333')].decode(errors='ignore')
        if len(identity)<14 or '-r' not in identity:return
        name=ad.service_data.get(bu('3334'),b'').decode(errors='replace').strip('\0') or ad.local_name or 'Android'
        identifier=peer_identifier(identity,device.address)
        self.devices[identifier]=device;self.peers[identifier]={'id':identifier,'name':name[:100],'last':time.monotonic(),**parse_peer_metadata(identity)}
    async def scanning(self):
        while True:
            if not self.scan_enabled or not self.discovering:
                emit('peers',peers=[]);await asyncio.sleep(1);continue
            try:
                async with BleakScanner(detection_callback=self.discovered,service_uuids=[bu('3333')]) as scanner:
                    self.scanner=scanner
                    while self.scan_enabled and self.discovering:
                        now=time.monotonic();emit('peers',peers=[{k:v for k,v in p.items() if k!='last'} for p in self.peers.values() if now-p['last']<15]);await asyncio.sleep(2)
            except asyncio.CancelledError:raise
            except Exception as e:
                emit('scan_status',detail=t(f'Check Bluetooth: {e}',f'请检查蓝牙：{e}'));await asyncio.sleep(5)
    async def send(self,peer_id,paths,peer_label=None):
        if self.session:emit('error',detail=t('Wait for the current transfer to finish.','请等待当前传输完成。'));return
        if peer_id not in self.devices:emit('error',detail=t('Choose the recipient again.','请重新选择接收设备。'));return
        s={'id':uuid.uuid4().hex,'direction':'send','peer':peer_label[:200] if isinstance(peer_label,str) and peer_label else self.peers[peer_id]['name']};self.session=s;s['task']=asyncio.current_task();self.read_state()
        runner=None;client=None;ws=None
        try:
            self.update(s,'preparing',name=Path(paths[0]).name if paths else '',count=len(paths))
            if not 1<=len(paths)<=10000:raise ValueError(t('Choose files to send.','请选择要发送的文件。'))
            files=[];names=set();total=0
            for raw in paths:
                p=Path(raw).resolve(strict=True)
                if not p.is_file():raise ValueError(t('Compress folders into ZIP files before sending.','请将文件夹压缩为 ZIP 后发送。'))
                name=safe_name(p.name)
                if name.casefold() in names:raise ValueError(t('Send files with identical names separately.','请分开发送同名文件。'))
                names.add(name.casefold());total+=p.stat().st_size;files.append(p)
            with tempfile.TemporaryDirectory(prefix='anDrop-send-') as td:
                root=Path(td);archive=root/'files.zip'
                if shutil.disk_usage(root).free<total+16*1024*1024:raise ValueError(t('Not enough space to prepare these files.','没有足够空间准备发送文件。'))
                with zipfile.ZipFile(archive,'w',zipfile.ZIP_STORED,allowZip64=True) as z:
                    for p in files:
                        with await asyncio.to_thread(p.open,'rb') as src,z.open(p.name,'w',force_zip64=True) as out:
                            while chunk:=src.read(1024*1024):out.write(chunk);await asyncio.sleep(0)
                with zipfile.ZipFile(archive) as z:total=sum(e.file_size for e in z.infolist())
                keys=Keys();done=asyncio.get_running_loop().create_future();queue=asyncio.Queue();allowed_ip=None;port=0;offered=False;downloaded=False;lan_confirmed=asyncio.Event()
                certkey=ec.generate_private_key(ec.SECP256R1());name=x509.Name([x509.NameAttribute(NameOID.COMMON_NAME,'anDrop')]);now=datetime.datetime.now(datetime.timezone.utc)
                cert=x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(certkey.public_key()).serial_number(x509.random_serial_number()).not_valid_before(now-datetime.timedelta(minutes=1)).not_valid_after(now+datetime.timedelta(days=1)).sign(certkey,hashes.SHA256())
                (root/'cert').write_bytes(cert.public_bytes(serialization.Encoding.PEM));(root/'key').write_bytes(certkey.private_bytes(serialization.Encoding.PEM,serialization.PrivateFormat.PKCS8,serialization.NoEncryption()));(root/'key').chmod(0o600)
                context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);context.load_cert_chain(root/'cert',root/'key')
                async def socket_handler(req):
                    nonlocal ws,offered,allowed_ip
                    candidate=ipaddress.ip_address(req.remote)
                    if not candidate.is_private or candidate.is_loopback or ws is not None:raise web.HTTPForbidden()
                    allowed_ip=req.remote
                    ws=web.WebSocketResponse(max_msg_size=131072);await ws.prepare(req)
                    emit('diagnostic',detail='WebSocket connected')
                    async def udp():
                        try:
                            await asyncio.sleep(.15)
                            async def burst():
                                with socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as sock:
                                    for _ in range(256):sock.sendto(bytes(4096),(req.remote,port+1));await asyncio.sleep(.001)
                            await retry_local_route(burst)
                            emit('diagnostic',detail='Bandwidth probes sent')
                        except Exception as e:
                            emit('diagnostic',detail=f'Bandwidth probe failed: {e}')
                            if not done.done():done.set_exception(e)
                    udp_task=asyncio.create_task(udp())
                    await ws.send_str(wire('action',0,'wlanBandwidth',{}))
                    try:
                        async for m in ws:
                            if m.type!=WSMsgType.TEXT:continue
                            kind,index,action,p=parse_wire(m.data)
                            emit('diagnostic',detail=f'{kind}:{index}:{action}')
                            if kind=='ack' and action=='wlanBandwidth':await ws.send_str(wire('action',1,'versionNegotiation',{'versions':[1],'version':1}))
                            elif kind=='ack' and action=='versionNegotiation':
                                await asyncio.wait_for(lan_confirmed.wait(),8)
                                offered=True
                                await ws.send_str(wire('action',2,'sendRequest',{'id':s['id'],'senderId':s['id'][:12],'senderName':self.name,'fileName':files[0].name,'fileCount':len(files),'number':str(len(files)),'totalSize':total,'mimeType':'file/*','wlan':True}))
                            elif kind=='action':
                                await ws.send_str(wire('ack',index,action,p))
                                if action=='status' and p.get('taskId')==s['id']:
                                    if p.get('type')==1 and downloaded:
                                        if not done.done():done.set_result(True)
                                    elif p.get('type') in (2,3):
                                        if not done.done():done.set_exception(ValueError(t('The phone cancelled the transfer.','手机已取消传输。')))
                    finally:udp_task.cancel()
                    return ws
                async def download(req):
                    nonlocal downloaded
                    emit('diagnostic',detail=f'Download request: peer={req.remote==allowed_ip}, offered={offered}, task={req.query.get("taskId")==s["id"]}')
                    if req.remote!=allowed_ip or not offered or req.query.get('taskId')!=s['id']:raise web.HTTPForbidden()
                    response=web.StreamResponse(status=200,headers={'Content-Type':'application/zip','Content-Length':str(archive.stat().st_size),'Cache-Control':'no-store'})
                    await response.prepare(req);sent=0
                    with archive.open('rb') as src:
                        while chunk:=src.read(1024*1024):
                            await response.write(chunk);sent+=len(chunk);self.progress(s,min(sent,total),total)
                    downloaded=True;await response.write_eof();return response
                app=web.Application(client_max_size=131072);app.router.add_get('/websocket',socket_handler);app.router.add_get('/download',download)
                client=BleakClient(self.devices[peer_id],timeout=15)
                await client.connect();self.update(s,'connecting',total=total,count=len(files))
                reply=json.loads(await asyncio.wait_for(client.read_gatt_char(bu('9897')),5))
                if reply.get('state')!=0:raise ValueError(t('The phone is busy. Please try again shortly.','手机正忙，请稍后重试。'))
                keys.derive(reply['key'])
                try:await client.start_notify(bu('9898'),lambda _,value:queue.put_nowait(bytes(value)))
                except Exception as e:
                    # OPPO omits a CCC descriptor, but sends notifications. CoreBluetooth delivers them after this request.
                    if 'CBATTErrorDomain Code=10' not in str(e):raise
                initial={'key':keys.public,'version':keys.encrypt('10014'),'pv':4,'isFast':0,'number':keys.encrypt(str(len(files))),'type':keys.encrypt('file/*'),'device_name':keys.encrypt(self.name),'random_code':keys.encrypt('')}
                await client.write_gatt_char(bu('9896'),json.dumps(initial,separators=(',',':')).encode(),response=True)
                self.update(s,'waiting',name=files[0].name,count=len(files),total=total)
                async with asyncio.timeout(60):
                    while True:
                        raw=await queue.get()
                        if raw==b'3':raise ValueError(t('The recipient declined the files.','对方已拒绝接收文件。'))
                        if raw.startswith(b'{'):
                            p=json.loads(raw)
                            if 'wlan' in p and 'wlan_accept' not in p:break
                # Bind only the interface leading to the BLE-selected peer, and admit only its address.
                allowed_ip=keys.decrypt(p['ip'])
                # The first address can be the phone's dormant hotspot address. The LAN address is
                # supplied after the TLS WebSocket connection; use an active local IPv4 interface.
                local=self.local_ipv4()
                runner=web.AppRunner(app,access_log=None);await runner.setup();site=web.TCPSite(runner,local,0,ssl_context=context);await site.start();port=site._server.sockets[0].getsockname()[1]
                allowed_ip=None
                await client.write_gatt_char(bu('9896'),json.dumps({'wlan':'wlan','ip':keys.encrypt(local),'port':keys.encrypt(str(port))},separators=(',',':')).encode(),response=True)
                self.update(s,'connecting')
                async with asyncio.timeout(20):
                    while True:
                        raw=await queue.get()
                        if not raw.startswith(b'{'):continue
                        p=json.loads(raw)
                        if 'wlan_accept' in p:
                            if not p['wlan_accept']:raise ValueError(t('Connect this Mac and your phone to the same Wi-Fi.','请将 Mac 和手机连接到同一 Wi-Fi。'))
                            confirmed=keys.decrypt(p['ip'])
                            if allowed_ip!=confirmed:raise ValueError('Peer address mismatch')
                            lan_confirmed.set()
                            break
                self.update(s,'transferring',total=total,completed=0)
                await asyncio.wait_for(done, max(120,total/(256*1024)))
                self.update(s,'complete',count=len(files),total=total,completed=total,files=[])
                await asyncio.sleep(.6)
        except asyncio.CancelledError:self.update(s,'cancelled')
        except TimeoutError:
            detail=t('No response. Keep the phone unlocked, enable its sharing feature, and accept the transfer notification.', '未收到回应。请解锁手机、开启互传功能并接受传输通知。') if s.get('state')=='waiting' else t('The transfer connection timed out. Check that both devices use the same Wi-Fi, then try again.','传输连接超时。请确认两台设备连接同一 Wi-Fi，然后重试。')
            self.update(s,'failed',detail=detail)
        except Exception as e:self.update(s,'failed',detail=t(f'Send failed: {e or type(e).__name__}',f'发送失败：{e or type(e).__name__}'))
        finally:
            if client and client.is_connected:
                if s.get('state')!='complete':
                    try:await client.write_gatt_char(bu('9894'),b'cancel',response=True)
                    except Exception:pass
                await client.disconnect()
            if ws is not None and not ws.closed:await ws.close()
            if runner:await runner.cleanup()
            await self.reset(s)
    def local_ipv4(self):
        # Ask macOS for the active primary interface. No external connection is made.
        import subprocess
        route=subprocess.check_output(['/sbin/route','-n','get','default'],stderr=subprocess.DEVNULL,text=True)
        interface=next(line.split(':',1)[1].strip() for line in route.splitlines() if 'interface:' in line)
        address=subprocess.check_output(['/usr/sbin/ipconfig','getifaddr',interface],text=True).strip()
        if not ipaddress.ip_address(address).is_private:raise ValueError(t('Connect to a local Wi-Fi network.','请连接到本地 Wi-Fi。'))
        return address
    async def command(self,obj):
        global LANG
        try:
            command=obj.get('command')
            if command=='configure':
                LANG=obj.get('language','en')
                self.destination=obj.get('destination',self.destination);self.name=obj.get('name',self.name);self.read_state()
            elif command=='enabled':self.scan_enabled=bool(obj.get('value'))
            elif command=='scan':self.discovering=bool(obj.get('value'))
            elif command=='subscribe':
                if obj.get('uuid')=='9895':self.notify('ready',obj.get('central'))
            elif command=='write':await self.receive_write(obj)
            elif command=='decision':
                future=self.decisions.get(obj.get('id'))
                if future and not future.done():future.set_result(bool(obj.get('accept')))
            elif command=='send':await self.send(obj['peer'],obj['paths'],obj.get('peer_label'))
            elif command=='cancel' and self.session and self.session['id']==obj.get('id'):
                s=self.session
                if s.get('task'):s['task'].cancel()
                else:
                    future=self.decisions.get(s['id'])
                    if future and not future.done():future.set_result(False)
                    else:self.notify('cancel',s.get('central'));self.update(s,'cancelled');await self.reset(s)
        except Exception as e:
            if self.session:
                s=self.session;self.notify('cancel',s.get('central'));self.update(s,'failed',detail=str(e));await self.reset(s)
            else:emit('error',detail=str(e))
    async def run(self):
        self.read_state();self.launch(self.scanning());emit('ready')
        reader=asyncio.StreamReader(limit=1048576);protocol=asyncio.StreamReaderProtocol(reader)
        await asyncio.get_running_loop().connect_read_pipe(lambda:protocol,sys.stdin)
        while line:=await reader.readline():
            try:self.launch(self.command(json.loads(line)))
            except Exception:emit('error',detail='Invalid app command')
        for task in list(self.jobs):task.cancel()
        await asyncio.gather(*self.jobs,return_exceptions=True)

if __name__=='__main__':
    os.umask(0o077)
    asyncio.run(Engine().run())
