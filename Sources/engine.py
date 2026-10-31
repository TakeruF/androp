# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 anDrop contributors

"""anDrop local interoperability engine. JSON-lines IPC with its native host.
No cloud, saved peer credentials, or USB transport. One transfer at a time.
"""
import asyncio, base64, datetime, errno, hashlib, ipaddress, json, os, shutil, signal, socket, ssl, stat, sys, tempfile, time, uuid, zipfile
from pathlib import Path, PurePosixPath
from peer_metadata import parse_peer_metadata, peer_identifier
from file_types import offer_mime_type
from sandbox_files import BookmarkAccess
from motion_photos import MotionPhotoError, prepare_send, materialize_received
from network_routes import lan_addresses, private_ipv4, direct_local_address, interface_for_address, bind_interface, lan_socket, client_socket_factory
from aiohttp import web, ClientSession, ClientTimeout, TCPConnector, Fingerprint, WSMsgType, ClientConnectionError, ClientSSLError, ServerFingerprintMismatch, WSServerHandshakeError
from bleak import BleakClient, BleakScanner
from cryptography import x509
from cryptography.x509.oid import NameOID
from cryptography.hazmat.primitives import serialization, hashes, padding
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

PEER_TTL = 10.0

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

def control_message(message,diagnostic):
    # Some sharing implementations send the same UTF-8 control protocol as
    # WebSocket binary frames. Apply the identical size and protocol validation;
    # never decode arbitrary file data or include payload values in diagnostics.
    message_type=message.type.name.lower()
    diagnostic('control_message',message_type=message_type)
    if message.type==WSMsgType.TEXT:raw=message.data
    elif message.type==WSMsgType.BINARY:
        if len(message.data)>131072:raise ValueError('Invalid protocol message')
        raw=message.data.decode('utf-8')
    elif message.type in (WSMsgType.CLOSE,WSMsgType.CLOSED,WSMsgType.CLOSING):
        raise ConnectionResetError('Peer closed the control channel')
    elif message.type==WSMsgType.ERROR:
        error=message.data
        if isinstance(error,Exception):raise error
        raise ConnectionError('Control channel failed')
    else:raise ValueError('Unsupported control frame')
    result=parse_wire(raw)
    action=result[2] if result[2] in ('wlanBandwidth','versionNegotiation','sendRequest','status') else 'other'
    diagnostic('control_action',protocol_action=action)
    return result

def send_offer_diagnostic(payload,transfer_id):
    fields={'wlan','wlan_accept','ip','port','ssid','psk','reuse','key','state','number','type','taskId','id','status','reason'}
    kind=('lan_accepted' if payload.get('wlan_accept') is True else 'lan_rejected') if 'wlan_accept' in payload else ('lan_request' if 'wlan' in payload else 'direct_request' if 'ssid' in payload else 'reuse_request' if 'reuse' in payload else 'other')
    emit('diagnostic',detail='send_offer_fields',transfer_id=transfer_id,
         offer_fields=sorted(fields.intersection(payload)),offer_kind=kind)

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

def sender_identifier(value):
    """A protocol identifier, never a display name, account, address, or task ID.

    It is self-reported, not cryptographic authentication. Hash at rest to avoid
    retaining vendor/account suffixes. Missing IDs cannot gain persistent trust.
    """
    if not isinstance(value,str) or not 8<=len(value)<=256 or value!=value.strip() or any(ord(c)<33 for c in value):
        return None
    return 'sender:' + hashlib.sha256(value.encode('utf-8')).hexdigest()


def valid_trust_identifier(value):
    if not isinstance(value,str):return None
    for prefix in ('sender:', 'huawei-key:'):
        if value.startswith(prefix) and len(value)==len(prefix)+64 and all(c in '0123456789abcdef' for c in value[len(prefix):]):return value
    try:return str(uuid.UUID(value)).upper()
    except ValueError:return None


def local_endpoint(host, port):
    ip=ipaddress.ip_address(host)
    if not private_ipv4(host) or not 1<=port<65535:
        raise ValueError('Invalid local endpoint')
    direct=direct_local_address(host)
    if direct:return direct
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

class TransferError(ValueError):
    """A deliberate, localized message that is safe to show in a notification."""


def connection_error_fields(error):
    """Finite diagnostic metadata only; never stringify errors or endpoints.

    aiohttp wraps the original OSError in os_error, sometimes without errno.
    Inspect only bounded exception metadata and exact SDK message prefixes.
    This classification must not affect connection retries or permission checks.
    """
    pending=[error];seen=set();issue=None
    prefixes=(('no matching local address with family=','local_address_family_mismatch'),
              ('Multiple exceptions:','multiple_socket_errors'),
              ('no interface with this name','interface_unavailable'))
    for _ in range(8):
        if not pending:break
        current=pending.pop(0)
        if not isinstance(current,BaseException) or id(current) in seen:continue
        seen.add(id(current))
        number=getattr(current,'errno',None)
        if type(number) is int and -65535<=number<=65535:return {'errno':number}
        if issue is None and isinstance(current,(OSError,RuntimeError)):
            for value in current.args[:2]:
                if type(value) is str:
                    issue=next((code for prefix,code in prefixes if value.startswith(prefix)),None)
                    if issue:break
        if isinstance(current,ClientConnectionError):
            nested=getattr(current,'os_error',None)
            if isinstance(nested,BaseException):pending.append(nested)
        pending.extend(item for item in (current.__cause__,current.__context__) if isinstance(item,BaseException))
    return {'connection_issue':issue or 'errno_unavailable'}


def transfer_error_detail(error,receiving=True):
    if isinstance(error,TransferError):return str(error)
    if isinstance(error,MotionPhotoError):
        return t('Could not prepare this Live Photo. Export its original image and paired video, then choose them together.', '无法准备此实况照片。请导出原始照片与配对视频，然后一起选择。')
    if isinstance(error,(ssl.SSLError,ClientSSLError,ServerFingerprintMismatch)):
        return t('Could not establish a secure connection with the other device. Keep its sharing screen open and try again.','无法与对方设备建立安全连接。请保持对方互传页面打开后重试。')
    if isinstance(error,PermissionError):
        return t('File access was denied. Check the selected folder and file permissions.','文件访问被拒绝。请检查所选文件夹和文件的访问权限。')
    if isinstance(error,OSError) and error.errno==errno.ENOSPC:
        return t('Not enough free disk space.','磁盘空间不足。')
    if isinstance(error,(FileNotFoundError,NotADirectoryError,IsADirectoryError)):
        return t('The save folder is unavailable. Choose a folder in Settings and try again.','保存文件夹不可用。请在设置中重新选择文件夹后重试。') if receiving else t('A selected file is no longer available. Choose the files again.','所选文件已不可用。请重新选择文件。')
    if isinstance(error,TimeoutError):
        return t('The connection timed out. Keep sharing open on the other device and try again.','连接超时。请保持对方互传页面打开后重试。')
    if isinstance(error,(ConnectionResetError,ConnectionAbortedError)) or getattr(error,'errno',None) in (errno.ECONNRESET,errno.ECONNABORTED):
        return t('The other device closed the connection. Keep its sharing screen open and try again.','对方设备断开了连接。请保持对方互传页面打开后重试。')
    if isinstance(error,(ClientConnectionError,ConnectionError,OSError)):
        return t('Could not reach the other device. Check local network access, VPN routing, and other interconnect sessions.','无法连接到对方设备。请检查本地网络权限、VPN 路由及其他设备互联连接。')
    if isinstance(error,(ValueError,zipfile.BadZipFile)):
        return t('The other device sent invalid or unsupported file information. Please try a different file.','对方发送的文件信息无效或暂不支持。请尝试其他文件。') if receiving else t('Could not prepare the selected files. Please choose different files.','无法准备所选文件。请尝试其他文件。')
    return t('Could not receive the files. Keep sharing open on the other device and try again.','无法接收文件。请保持对方互传页面打开后重试。') if receiving else t('Could not send the files. Keep sharing open on the other device and try again.','无法发送文件。请保持对方互传页面打开后重试。')


async def connect_receive_channel(operation,diagnostic):
    # Retry only before a WebSocket is established: no transfer metadata or file
    # bytes are replayed. Keep certificate/protocol failures fatal.
    delays=(.2,.4,.8)
    transient={errno.EHOSTUNREACH,errno.ECONNRESET,errno.ECONNREFUSED,errno.ECONNABORTED}
    async with asyncio.timeout(10):
        for attempt in range(len(delays)+1):
            diagnostic('receive_connect_attempt',attempt=attempt+1)
            try:return await operation()
            except (ClientSSLError,ssl.SSLError,ServerFingerprintMismatch,WSServerHandshakeError):raise
            except OSError as error:
                diagnostic('receive_connect_interrupted',error_type=type(error).__name__,**connection_error_fields(error))
                if error.errno not in transient or attempt==len(delays):raise
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
    if shutil.disk_usage(destination).free < total+16*1024*1024: raise TransferError(t('Not enough free disk space.','磁盘空间不足。'))
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
                    from received_files import mark_download
                    mark_download(tmp)
                    for attempt in range(10000):
                        stem=Path(name).stem;suffix=Path(name).suffix
                        final=destination/(name if not attempt else f'{stem} ({attempt}){suffix}')
                        try: os.link(tmp,final);break
                        except FileExistsError: continue
                    else: raise TransferError(t('Too many files with the same name.','同名文件过多。'))
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

async def stream_archive(response,archive,progress):
    """Report actual ZIP response bytes, including overhead and empty files."""
    total=archive.stat().st_size;sent=0;progress(0,total)
    with archive.open('rb') as source:
        while chunk:=source.read(1024*1024):
            await response.write(chunk);sent+=len(chunk);progress(sent,total)
    await response.write_eof()
    return total

class Engine:
    def __init__(self):
        self.trusted_only=False;self.trusted_ids=set();self.auto_accept_trusted=True
        self.destination=str(Path.home()/'Downloads');self.name='anDrop Mac';self.keys=Keys();self.session=None
        self.scanner=None;self.scan_token=None;self.devices={};self.peers={};self.decisions={};self.scan_enabled=True;self.discovering=False;self.jobs=set()
        self.outgoing={}
        self.destination_access=None
        self.huawei_enabled=True
        from huawei_runtime import HuaweiRuntime
        self.huawei=HuaweiRuntime(self,emit)
    def launch(self,coro):
        task=asyncio.create_task(coro);self.jobs.add(task);task.add_done_callback(self.jobs.discard);return task
    def read_state(self):
        emit('ble_read',uuid='9898',value={'state':1 if self.busy else 0,'key':self.keys.public,'version':'10014','isFast':0,'pv':4})
    @property
    def busy(self):
        return bool(self.session or self.outgoing)
    def start_outgoing(self,s,peer_id):
        # Reserve before the first await so concurrent commands cannot duplicate
        # a destination or steal a receive session. Each sender owns its keys,
        # sockets, archive and cancellation task.
        if self.session or s['id'] in self.outgoing or any(x['peer_id']==peer_id for x in self.outgoing.values()):
            return False
        s['peer_id']=peer_id;s['task']=asyncio.current_task()
        self.outgoing[s['id']]=s;self.read_state();return True
    def notify(self,value,central=None):
        data=value if isinstance(value,str) else json.dumps(value,separators=(',',':'))
        emit('ble_notify',uuid='9895',data=base64.b64encode(data.encode()).decode(),central=central)
    def update(self,session,state,**kwargs):
        session['state']=state
        emit('transfer',id=session['id'],direction=session['direction'],peer=session.get('peer','Android'),state=state,device_identifier=session.get('device_identifier') or session.get('central'),transport_identifier=session.get('central'),device_kind=session.get('kind'),device_brand=session.get('brand'),**kwargs)
    def complete_received_files(self,session,files,count,total):
        fields={}
        if count==1 and any(file.get('kind')=='live_photo' for file in files):
            fields['name']=t('Live Photo','实况照片')
        self.update(session,'complete',files=files,count=count,total=total,completed=total,**fields)
    def progress(self,s,n,total):
        now=time.monotonic()
        if now-s.get('last_progress',0)>.2 or n>=total:
            s['last_progress']=now;self.update(s,'transferring',completed=n,total=total)
    async def reset(self,s):
        if self.outgoing.get(s['id']) is s:
            self.outgoing.pop(s['id']);self.read_state()
        if self.session is s:
            self.session=None;self.keys=Keys();self.read_state()
    def may_receive(self,central,sender=None):
        return not self.trusted_only or bool(central and central.upper() in self.trusted_ids) or bool(sender and sender in self.trusted_ids)
    def may_negotiate(self,central):
        # The sender ID arrives in TLS sendRequest, after GATT negotiation. This
        # permits metadata only; receipt and the download endpoint stay gated.
        return self.scan_enabled and (self.may_receive(central) or any(x.startswith('sender:') for x in self.trusted_ids))
    async def approve_receive(self,s,metadata):
        if s.get('protocol')=='huawei':
            # Set only by the receive handshake after proving possession of the
            # peer RSA key. Discovery names, IPs and senderId never authorize it.
            identity=valid_trust_identifier(s.get('device_identifier'))
            if not identity or not identity.startswith('huawei-key:'):identity=None
        else:identity=sender_identifier(metadata.get('senderId'))
        if identity:s['device_identifier']=identity
        enabled=lambda:self.huawei_enabled if s.get('protocol')=='huawei' else self.scan_enabled
        if not enabled() or not self.may_receive(s['central'],identity):
            emit('diagnostic',detail='receive_untrusted_sender')
            return False
        # Match the transfer identity, never the display name, discovery ID or
        # legacy Bluetooth address. This applies independently of receive scope.
        if self.auto_accept_trusted and identity and identity in self.trusted_ids:
            return self.session is s
        future=asyncio.get_running_loop().create_future();self.decisions[s['id']]=future
        self.update(s,'request',count=s['count'],name=str(metadata.get('fileName',t('Files','文件')))[:240],total=int(metadata['totalSize']))
        try:accepted=await asyncio.wait_for(future,28)
        except TimeoutError:accepted=False
        finally:self.decisions.pop(s['id'],None)
        return bool(accepted and self.session is s and enabled() and self.may_receive(s['central'],identity))
    def may_access_control(self,central):
        if not isinstance(central,str):return False
        try:identifier=str(uuid.UUID(central)).upper()
        except (ValueError,AttributeError):return False
        session=self.session
        if session and session.get('direction')=='receive' and session.get('state') in ('verifying','request','connecting','transferring','confirming') and session.get('central','').upper()==identifier:
            return True
        return self.may_negotiate(identifier)
    async def receive_write(self,obj):
        central=obj.get('central','')
        if obj.get('uuid')!='9896': return
        raw=base64.b64decode(obj.get('data',''))
        if len(raw)>65536: return
        payload=json.loads(raw)
        if not isinstance(payload,dict): return
        if 'key' in payload:
            if not self.may_negotiate(central): self.notify('3',central);return
            if self.busy: self.notify('3',central);return
            keys=self.keys;keys.derive(payload['key']);count=int(keys.decrypt(payload['number']))
            if not 1<=count<=10000: self.notify('3',central);return
            s={'id':uuid.uuid4().hex,'direction':'receive','peer':keys.decrypt(payload.get('device_name',''))[:100] or 'Android','central':central,'keys':keys,'count':count}
            for field,target in [('vender','brand'),('device_type','kind')]:
                if field in payload:
                    try:
                        value=keys.decrypt(payload[field])
                        if target=='kind':value={'0':'phone','1':'tablet'}.get(value)
                        if value:s[target]=value[:32]
                    except (ValueError,TypeError):pass
            if 'ip' in payload:
                hint=keys.decrypt(payload['ip'])
                if private_ipv4(hint):s['network_hint']=hint
            self.session=s;self.read_state()
            self.update(s,'verifying');self.notify('6',central)
            self.launch(self.expire_receive_offer(s,central))
        elif self.session and self.session.get('central')==central:
            s=self.session;k=s['keys']
            if 'reuse' in payload and 'port' in payload and 'ip' not in payload and s.get('network_hint') and k.decrypt(payload['reuse'])=='true':
                payload={**payload,'ip':k.encrypt(s['network_hint'])}
            if 'ip' in payload and 'port' in payload:
                host=k.decrypt(payload['ip']);port=int(k.decrypt(payload['port']))
                # A peer may abandon its first WLAN listener and announce a new
                # hotspot port. Its LAN address from THIS BLE exchange remains a
                # candidate for that port; never borrow another device's history.
                if 'wlan' in payload and private_ipv4(host):s['lan_hint']=host
                if 'ssid' in payload:
                    lan=s.get('lan_hint') or s.get('network_hint')
                    if lan and private_ipv4(lan) and direct_local_address(lan):
                        host=lan
                await self.replace_receive_route(s,host,port,'wlan' in payload)
            elif 'ssid' in payload and 'task' not in s:
                self.notify('cancel',central);self.update(s,'failed',detail=t('The other device requested a direct Wi-Fi connection that is not reachable from this Mac. Disconnect its other interconnect session and try again.','对方请求的 Wi-Fi 直连网络无法从此 Mac 访问。请断开对方与其他设备的互联后重试。'));await self.reset(s)
    async def replace_receive_route(self,s,host,port,is_lan):
        async with s.setdefault('route_lock',asyncio.Lock()):
            if self.session is not s or s.get('channel_established'):return
            route=(host,port)
            if s.get('route')==route:return
            local=local_endpoint(host,port)
            if s.get('route_changes',0)>=4:
                raise TransferError(t('The other device keeps changing its connection. Please try again.','对方设备反复切换连接，请重试。'))
            previous=s.get('task')
            if previous:
                # Cancel only the obsolete connect attempt. Do not cancel the
                # protocol transfer, reset its keys, or emit a terminal result.
                s.setdefault('superseded_tasks',set()).add(previous)
                previous.cancel();await asyncio.gather(previous,return_exceptions=True)
                s['superseded_tasks'].discard(previous)
                old_udp=s.pop('route_udp',None)
                if old_udp:old_udp.close()  # Also covers a task cancelled before it starts.
                emit('diagnostic',detail='receive_endpoint_replaced')
            if self.session is not s or s.get('cancel_requested'):return
            s['route']=route;s['route_changes']=s.get('route_changes',0)+1;s['local_address']=local
            emit('diagnostic',detail='receive_network_offer',transfer_id=s['id'],mode='lan' if is_lan else 'direct')
            udp=None
            try:
                udp=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
                bind_interface(udp,interface_for_address(local));udp.bind((local,port+1));udp.setblocking(False)
            except OSError as error:
                if udp:udp.close()
                udp=None
                emit('diagnostic',detail='receive_udp_probe_unavailable',phase='bind',error_type=type(error).__name__,errno=error.errno)
            s['route_udp']=udp
            if is_lan:self.notify({'wlan':'wlan','wlan_accept':True,'ip':s['keys'].encrypt(local)},s['central'])
            s['task']=self.launch(self.receive(s,host,port,udp))

    async def expire_receive_offer(self,s,central):
        await asyncio.sleep(15)
        if self.session is s and s.get('state') in ('verifying','connecting') and 'task' not in s:
            self.notify('cancel',central);self.update(s,'failed',detail=t('The other device did not finish network negotiation. Keep sharing open and check whether another interconnect session is using the connection.','对方未完成网络协商。请保持互传页面打开，并检查是否有其他设备互联正在占用连接。'));await self.reset(s)
    async def receive(self,s,host,port,udp):
        async def bandwidth():
            if udp is None:return 0.0
            total=0;start=None;loop=asyncio.get_running_loop()
            while total<262144:
                packet,addr=await loop.sock_recvfrom(udp,4096)
                if addr[0]!=host:continue
                start=start or time.monotonic();total+=len(packet)
            return total/1048576/max(time.monotonic()-start,.001)
        bw=asyncio.create_task(bandwidth());ws=None;taskid='';phase='connect'
        def diagnostic(code,**fields):emit('diagnostic',detail=code,transfer_id=s['id'],phase=phase,**fields)
        try:
            self.update(s,'verifying')
            context=ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT);context.check_hostname=False;context.verify_mode=ssl.CERT_NONE
            timeout=ClientTimeout(total=None,sock_connect=8,sock_read=35)
            local=udp.getsockname()[0] if udp else s['local_address']
            connector=TCPConnector(local_addr=(local,0),socket_factory=client_socket_factory(local))
            async with ClientSession(timeout=timeout,trust_env=False,connector=connector) as client:
                async with await connect_receive_channel(lambda: client.ws_connect(f'https://{host}:{port}/websocket',ssl=context,max_msg_size=131072),diagnostic) as ws:
                    s['channel_established']=True
                    phase='bandwidth';diagnostic('receive_connected')
                    connection=ws._response.connection
                    sslobject=connection.transport.get_extra_info('ssl_object')
                    fingerprint=hashlib.sha256(sslobject.getpeercert(binary_form=True)).digest()
                    try:speed=await asyncio.wait_for(bw,2)
                    except TimeoutError:
                        # UDP probes are advisory. A working TLS connection can
                        # still transfer files when a VPN/firewall drops UDP.
                        speed=0.0;diagnostic('receive_udp_probe_unavailable')
                    phase='negotiate';diagnostic('receive_negotiating')
                    await ws.send_str(wire('ack',0,'wlanBandwidth',{'speed':f'{speed:.2f}'}))
                    async with asyncio.timeout(45):
                        while True:
                            kind,index,name,p=control_message(await ws.receive(),diagnostic)
                            if kind!='action':continue
                            if name=='wlanBandwidth':await ws.send_str(wire('ack',index,name,{'speed':f'{speed:.2f}'}))
                            elif name=='versionNegotiation':await ws.send_str(wire('ack',index,name,{'version':1,'threadLimit':1}))
                            elif name=='sendRequest':break
                            else:await ws.send_str(wire('ack',index,name))
                    count=int(p.get('fileCount',0));size=int(p.get('totalSize',-1));taskid=str(p.get('id',''))
                    if count!=s['count'] or size<0 or len(taskid)>256 or not taskid:raise ValueError('Invalid transfer metadata')
                    if not await self.approve_receive(s,p):
                        await ws.send_str(wire('action',101,'status',{'taskId':taskid,'type':3,'reason':'declined'}))
                        self.notify('3',s['central']);self.update(s,'declined');return
                    if shutil.disk_usage(self.destination).free<size*2+16*1024*1024:raise TransferError(t('Not enough free disk space.','磁盘空间不足。'))
                    await ws.send_str(wire('ack',index,name));self.update(s,'transferring',name=str(p.get('fileName',t('Files','文件')))[:240],count=count,total=size,completed=0)
                    phase='download';diagnostic('receive_download_start')
                    with tempfile.TemporaryDirectory(prefix='anDrop-',dir=self.destination) as td:
                        archive=Path(td)/'incoming.zip';limit=size+max(1048576,count*65536);downloaded=0
                        async with client.get(f'https://{host}:{port}/download',params={'taskId':taskid},ssl=Fingerprint(fingerprint)) as response:
                            if response.status!=200:raise TransferError(t('Could not download files from the other device.','无法从对方设备下载文件。'))
                            with archive.open('wb') as out:
                                async for chunk in response.content.iter_chunked(1024*1024):
                                    downloaded+=len(chunk)
                                    if downloaded>limit:raise ValueError('Transfer exceeds declared size')
                                    out.write(chunk);self.progress(s,min(downloaded,size),size)
                        phase='save';diagnostic('receive_save_start')
                        saved=await unpack(archive,self.destination,count,size,lambda n,t:self.progress(s,n,t))
                    await ws.send_str(wire('action',100,'status',{'taskId':taskid,'id':taskid,'type':1,'reason':'ok'}))
                    try:await asyncio.wait_for(ws.receive(),2)
                    except TimeoutError:pass
                    saved=await materialize_received(saved,diagnostic)
                    self.complete_received_files(s,saved,count,size)
        except asyncio.CancelledError:
            if asyncio.current_task() in s.get('superseded_tasks',()):return
            if ws and not ws.closed:
                try:await ws.send_str(wire('action',101,'status',{'taskId':taskid,'type':3,'reason':'user interrupt'}))
                except Exception:pass
            self.notify('cancel',s['central']);self.update(s,'cancelled')
        except Exception as e:
            diagnostic('receive_failed',error_type=type(e).__name__,**connection_error_fields(e))
            self.notify('cancel',s['central']);self.update(s,'failed',detail=transfer_error_detail(e))
        finally:
            bw.cancel()
            if udp:udp.close()
            if asyncio.current_task() not in s.get('superseded_tasks',()):await self.reset(s)
    def clear_peers(self):
        self.peers.clear();self.devices.clear();emit('peers',peers=[])
    def prune_peers(self):
        now=time.monotonic()
        for identifier in list(self.peers):
            if now-self.peers[identifier]['last']>=PEER_TTL:
                self.peers.pop(identifier,None);self.devices.pop(identifier,None)
    def publish_peers(self):
        self.prune_peers()
        emit('peers',peers=[{k:v for k,v in p.items() if k!='last'} for p in self.peers.values()]
             + (self.huawei.visible_peers() if self.huawei_enabled and self.discovering else []))
    def discovered(self,device,ad):
        if not self.scan_enabled or not self.discovering:return
        if bu('3333') not in ad.service_data:return  # A partial advertisement is not a withdrawal.
        identity=ad.service_data[bu('3333')].decode(errors='ignore')
        fields=identity.split('-')
        if len(identity)<14 or len(fields)<2 or fields[1] not in ('r','sr'):
            # Only revoke this endpoint, not a newer route after address rotation.
            removed=[key for key,value in self.devices.items() if value.address==device.address]
            for key in removed:self.devices.pop(key,None);self.peers.pop(key,None)
            if removed:self.publish_peers()
            return
        name=ad.service_data.get(bu('3334'),b'').decode(errors='replace').strip('\0') or ad.local_name or 'Android'
        identifier=peer_identifier(identity,device.address)
        self.devices[identifier]=device;self.peers[identifier]={'id':identifier,'name':name[:100],'last':time.monotonic(),**parse_peer_metadata(identity)}
    def discovery_callback(self,token):
        def found(device,ad):
            if self.scan_token is token:self.discovered(device,ad)
        return found
    async def scanning(self):
        while True:
            if not self.scan_enabled or not self.discovering:
                await asyncio.sleep(1);continue
            self.clear_peers()
            token=object();self.scan_token=token
            found=self.discovery_callback(token)
            try:
                options={}
                if sys.platform=='darwin':
                    from discovery import LiveScannerCoreBluetooth
                    options['backend']=LiveScannerCoreBluetooth
                async with BleakScanner(detection_callback=found,service_uuids=[bu('3333')],**options) as scanner:
                    self.scanner=scanner
                    try:
                        while self.scan_enabled and self.discovering:
                            self.publish_peers();await asyncio.sleep(1)
                    finally:
                        self.scan_token=None;self.scanner=None;self.clear_peers()
            except asyncio.CancelledError:
                self.scan_token=None;self.clear_peers();raise
            except Exception as e:
                self.scan_token=None;self.clear_peers()
                emit('scan_status',detail=t(f'Check Bluetooth: {e}',f'请检查蓝牙：{e}'));await asyncio.sleep(5)
    async def send(self,peer_id,paths,peer_label=None,request_id=None):
        if request_id and uuid.UUID(request_id).hex in self.outgoing:
            return  # Repeated delivery of one command must not corrupt its result.
        if isinstance(peer_id,str) and peer_id.startswith('huawei:'):
            await self.huawei.send(peer_id,paths,peer_label,request_id);return
        identifier=uuid.UUID(request_id).hex if request_id else uuid.uuid4().hex
        label=peer_label[:200] if isinstance(peer_label,str) and peer_label else self.peers.get(peer_id,{}).get('name','Android')
        s={'id':identifier,'direction':'send','peer':label}
        self.prune_peers()
        if not self.scan_enabled or not self.discovering or peer_id not in self.devices:
            self.publish_peers();self.update(s,'failed',detail=t('This device is no longer discoverable. Enable sharing on it and choose it again.','此设备已无法被发现。请在对方设备上开启互传后重新选择。'));return
        device=self.devices[peer_id]  # Keep the selected route while the chooser closes.
        s['device_identifier']=device.address
        if not self.start_outgoing(s,peer_id):
            self.update(s,'failed',detail=t('This device or the receiver is busy. Please try again shortly.','此设备或接收服务正忙，请稍后重试。'));return
        runner=None;client=None;ws=None;photo_workspace=None
        try:
            self.update(s,'preparing',name=Path(paths[0]).name if paths else '',count=len(paths))
            if not 1<=len(paths)<=10000:raise TransferError(t('Choose files to send.','请选择要发送的文件。'))
            photo_workspace=tempfile.TemporaryDirectory(prefix='anDrop-LivePhoto-send-')
            paths=await prepare_send(paths,photo_workspace.name)
            files=[];names=set();total=0
            for raw in paths:
                p=Path(raw).resolve(strict=True)
                if not p.is_file():raise TransferError(t('Compress folders into ZIP files before sending.','请将文件夹压缩为 ZIP 后发送。'))
                name=safe_name(p.name)
                if name.casefold() in names:raise TransferError(t('Send files with identical names separately.','请分开发送同名文件。'))
                names.add(name.casefold());total+=p.stat().st_size;files.append(p)
            with tempfile.TemporaryDirectory(prefix='anDrop-send-') as td:
                root=Path(td);archive=root/'files.zip'
                if shutil.disk_usage(root).free<total+16*1024*1024:raise TransferError(t('Not enough space to prepare these files.','没有足够空间准备发送文件。'))
                with zipfile.ZipFile(archive,'w',zipfile.ZIP_STORED,allowZip64=True) as z:
                    for p in files:
                        with await asyncio.to_thread(p.open,'rb') as src,z.open(p.name,'w',force_zip64=True) as out:
                            while chunk:=src.read(1024*1024):out.write(chunk);await asyncio.sleep(0)
                with zipfile.ZipFile(archive) as z:total=sum(e.file_size for e in z.infolist())
                mime_type=offer_mime_type(files)
                keys=Keys();done=asyncio.get_running_loop().create_future();queue=asyncio.Queue();allowed_ip=None;confirmed_ip=None;port=0;offered=False;downloaded=False;acknowledged=False;lan_confirmed=asyncio.Event();channel_connected=asyncio.Event()
                certkey=ec.generate_private_key(ec.SECP256R1());name=x509.Name([x509.NameAttribute(NameOID.COMMON_NAME,'anDrop')]);now=datetime.datetime.now(datetime.timezone.utc)
                cert=x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(certkey.public_key()).serial_number(x509.random_serial_number()).not_valid_before(now-datetime.timedelta(minutes=1)).not_valid_after(now+datetime.timedelta(days=1)).sign(certkey,hashes.SHA256())
                (root/'cert').write_bytes(cert.public_bytes(serialization.Encoding.PEM));(root/'key').write_bytes(certkey.private_bytes(serialization.Encoding.PEM,serialization.PrivateFormat.PKCS8,serialization.NoEncryption()));(root/'key').chmod(0o600)
                context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);context.load_cert_chain(root/'cert',root/'key')
                async def socket_handler(req):
                    nonlocal ws,offered,allowed_ip,acknowledged
                    candidate=ipaddress.ip_address(req.remote)
                    if not private_ipv4(req.remote) or ws is not None or (confirmed_ip and req.remote!=confirmed_ip):raise web.HTTPForbidden()
                    allowed_ip=req.remote
                    ws=web.WebSocketResponse(max_msg_size=131072);await ws.prepare(req);channel_connected.set()
                    emit('diagnostic',detail='WebSocket connected')
                    async def udp():
                        try:
                            await asyncio.sleep(.15)
                            async def burst():
                                with socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as sock:
                                    bind_interface(sock,interface_for_address(req.transport.get_extra_info('sockname')[0]))
                                    for _ in range(256):sock.sendto(bytes(4096),(req.remote,port+1));await asyncio.sleep(.001)
                            await retry_local_route(burst)
                            emit('diagnostic',detail='Bandwidth probes sent')
                        except Exception as e:
                            emit('diagnostic',detail=f'Bandwidth probe failed: {e}')
                            # A working control channel may proceed without the
                            # advisory UDP benchmark; the peer decides readiness.
                    udp_task=asyncio.create_task(udp())
                    await ws.send_str(wire('action',0,'wlanBandwidth',{}))
                    try:
                        async for m in ws:
                            kind,index,action,p=control_message(m,lambda code,**fields:emit('diagnostic',detail=code,transfer_id=s['id'],phase='negotiate',**fields))
                            emit('diagnostic',detail=f'{kind}:{index}:{action}')
                            if kind=='ack' and action=='wlanBandwidth':await ws.send_str(wire('action',1,'versionNegotiation',{'versions':[1],'version':1}))
                            elif kind=='ack' and action=='versionNegotiation':
                                await asyncio.wait_for(lan_confirmed.wait(),8)
                                offered=True
                                await ws.send_str(wire('action',2,'sendRequest',{'id':s['id'],'senderId':s['id'][:12],'senderName':self.name,'fileName':files[0].name,'fileCount':len(files),'number':str(len(files)),'totalSize':total,'mimeType':mime_type,'wlan':True}))
                            elif kind=='action':
                                await ws.send_str(wire('ack',index,action,p))
                                if action=='status' and p.get('taskId')==s['id']:
                                    if p.get('type')==1:
                                        acknowledged=True
                                        if downloaded and not done.done():done.set_result(True)
                                    elif p.get('type') in (2,3):
                                        if not done.done():done.set_exception(ValueError(t('The other device cancelled the transfer.','对方已取消传输。')))
                    finally:udp_task.cancel()
                    return ws
                async def download(req):
                    nonlocal downloaded
                    emit('diagnostic',detail=f'Download request: peer={req.remote==allowed_ip}, offered={offered}, task={req.query.get("taskId")==s["id"]}')
                    if req.remote!=allowed_ip or not offered or req.query.get('taskId')!=s['id']:raise web.HTTPForbidden()
                    response=web.StreamResponse(status=200,headers={'Content-Type':'application/zip','Content-Length':str(archive.stat().st_size),'Cache-Control':'no-store'})
                    await response.prepare(req)
                    try:
                        wire_total=await stream_archive(response,archive,lambda n,t:self.progress(s,n,t))
                    except Exception as e:
                        if not done.done():done.set_exception(e)
                        raise
                    downloaded=True
                    self.update(s,'confirming',completed=wire_total,total=wire_total)
                    if acknowledged and not done.done():done.set_result(True)
                    return response
                app=web.Application(client_max_size=131072);app.router.add_get('/websocket',socket_handler);app.router.add_get('/download',download)
                client=BleakClient(device,timeout=15)
                await client.connect();self.update(s,'connecting',total=total,count=len(files))
                reply=json.loads(await asyncio.wait_for(client.read_gatt_char(bu('9897')),5))
                if reply.get('state')!=0:raise TransferError(t('The other device is busy. Please try again shortly.','对方设备正忙，请稍后重试。'))
                keys.derive(reply['key'])
                try:await client.start_notify(bu('9898'),lambda _,value:queue.put_nowait(bytes(value)))
                except Exception as e:
                    # OPPO omits a CCC descriptor, but sends notifications. CoreBluetooth delivers them after this request.
                    if 'CBATTErrorDomain Code=10' not in str(e):raise
                # The approval card is shown from this BLE metadata, before the
                # receiver can see the later WebSocket sendRequest.
                initial={'key':keys.public,'version':keys.encrypt('10014'),'pv':4,'isFast':0,'number':keys.encrypt(str(len(files))),'type':keys.encrypt(mime_type),'device_name':keys.encrypt(self.name),'random_code':keys.encrypt('')}
                await client.write_gatt_char(bu('9896'),json.dumps(initial,separators=(',',':')).encode(),response=True)
                self.update(s,'waiting',name=files[0].name,count=len(files),total=total)
                async with asyncio.timeout(60):
                    while True:
                        raw=await queue.get()
                        if raw==b'3':
                            self.update(s,'declined',detail=t('The recipient declined the files.','对方已拒绝接收文件。'))
                            return
                        if raw.startswith(b'{'):
                            p=json.loads(raw)
                            if not isinstance(p,dict):raise ValueError('Invalid network offer')
                            send_offer_diagnostic(p,s['id'])
                            if 'wlan' in p and 'wlan_accept' not in p:break
                # Prefer a directly attached subnet; never advertise a VPN default
                # route or a dormant hotspot address as this Mac's LAN endpoint.
                peer_hint=keys.decrypt(p['ip'])
                candidates=lan_addresses(peer_hint)
                if not candidates:raise TransferError(t('No active local network address. Connect Wi-Fi or Ethernet and try again.','未找到可用的局域网地址。请连接 Wi-Fi 或以太网后重试。'))
                runner=web.AppRunner(app,access_log=None);await runner.setup()
                for candidate_index,local in enumerate(candidates):
                    listener=lan_socket(local)
                    try:
                        site=web.SockSite(runner,listener,ssl_context=context);await site.start()
                    except BaseException:listener.close();raise
                    port=listener.getsockname()[1]
                    allowed_ip=None;confirmed_ip=None;channel_connected.clear()
                    await client.write_gatt_char(bu('9896'),json.dumps({'wlan':'wlan','ip':keys.encrypt(local),'port':keys.encrypt(str(port))},separators=(',',':')).encode(),response=True)
                    self.update(s,'connecting')
                    async with asyncio.timeout(20):
                        while True:
                            raw=await queue.get()
                            if raw in (b'3',b'cancel'):raise TransferError(t('The recipient cancelled the transfer.','对方已取消传输。'))
                            if not raw.startswith(b'{'):continue
                            p=json.loads(raw)
                            if not isinstance(p,dict):raise ValueError('Invalid network offer')
                            send_offer_diagnostic(p,s['id'])
                            if 'wlan_accept' not in p:continue
                            if p['wlan_accept'] is not True:
                                if candidate_index+1==len(candidates):raise TransferError(t('The other device could not reach this Mac over the local network. Another interconnect session or network isolation may be blocking it.','对方无法通过局域网连接此 Mac。其他设备互联连接或网络隔离可能阻止了通信。'))
                                if ws is not None:await ws.close();ws=None
                                await site.stop();break
                            confirmed_ip=keys.decrypt(p['ip'])
                            if not private_ipv4(confirmed_ip):raise ValueError('Invalid peer address')
                            # GATT acknowledgement and the TLS connection can arrive in
                            # either order. Authorize only after both agree on the peer.
                            await channel_connected.wait()
                            if allowed_ip!=confirmed_ip:raise ValueError('Peer address mismatch')
                            lan_confirmed.set();break
                    if lan_confirmed.is_set():break
                await asyncio.wait_for(done, max(120,total/(256*1024)))
                self.update(s,'complete',count=len(files),total=total,completed=total,files=[])
                await asyncio.sleep(.6)
        except asyncio.CancelledError:self.update(s,'cancelled')
        except TimeoutError:
            emit('diagnostic',detail='send_failed',transfer_id=s['id'],phase=s.get('state'),error_type='TimeoutError')
            detail=t('No response. Keep the other device unlocked, enable sharing, and accept its transfer request.', '未收到回应。请解锁对方设备、开启互传，并确认接收请求。') if s.get('state')=='waiting' else t('The transfer connection timed out. Check local-network access, VPN routing, and other interconnect sessions, then try again.','传输连接超时。请检查局域网访问权限、VPN 路由及其他设备互联连接后重试。')
            self.update(s,'failed',detail=detail)
        except Exception as e:
            emit('diagnostic',detail='send_failed',transfer_id=s['id'],phase=s.get('state'),error_type=type(e).__name__,errno=getattr(e,'errno',None))
            self.update(s,'failed',detail=transfer_error_detail(e,receiving=False))
        finally:
            try:
                if client and client.is_connected:
                    if s.get('state')!='complete':
                        try:await client.write_gatt_char(bu('9894'),b'cancel',response=True)
                        except Exception:pass
                    await client.disconnect()
                if ws is not None and not ws.closed:await ws.close()
                if runner:await runner.cleanup()
            finally:
                if photo_workspace is not None:photo_workspace.cleanup()
                await self.reset(s)
    def local_ipv4(self):
        addresses=lan_addresses()
        if not addresses:raise TransferError(t('No active local network address. Connect Wi-Fi or Ethernet and try again.','未找到可用的局域网地址。请连接 Wi-Fi 或以太网后重试。'))
        return addresses[0]
    async def command(self,obj):
        global LANG
        try:
            command=obj.get('command')
            if command=='configure':
                LANG=obj.get('language','en')
                self.trusted_only=bool(obj.get('trusted_only',False))
                self.auto_accept_trusted=bool(obj.get('auto_accept_trusted',True))
                self.trusted_ids={identifier for value in obj.get('trusted_ids',[]) if (identifier:=valid_trust_identifier(value))}
                if 'destination' in obj:
                    access = BookmarkAccess([obj['destination_bookmark']], [obj['destination']]) if 'destination_bookmark' in obj else None
                    if os.environ.get('ANDROP_SANDBOXED') == '1' and access is None:
                        raise ValueError('Save folder access is unavailable')
                    if self.destination_access: self.destination_access.close()
                    self.destination_access=access
                    self.destination=obj['destination']
                self.name=obj.get('name',self.name);self.read_state()
                self.huawei_enabled=bool(obj.get('huawei_enabled',self.scan_enabled))
            elif command=='enabled':
                self.scan_enabled=bool(obj.get('value'))
                if not self.scan_enabled:self.clear_peers()
            elif command=='scan':
                value=bool(obj.get('value'))
                if not value or not self.discovering:self.clear_peers()
                self.discovering=value
            elif command=='subscribe':
                if obj.get('uuid')=='9895' and self.may_access_control(obj.get('central')):self.notify('ready',obj.get('central'))
            elif command=='write':await self.receive_write(obj)
            elif command=='huawei_datagram':self.huawei.datagram(obj)
            elif command=='decision':
                future=self.decisions.get(obj.get('id'))
                if future and not future.done():future.set_result(bool(obj.get('accept')))
            elif command=='send':
                if 'link' in obj or 'text' in obj:
                    emit('error',detail=t('URL and text sharing are not supported. Choose files to send.','不支持 URL 或文本共享，请选择文件发送。'))
                    return
                paths=obj.get('paths',[])
                if 'bookmarks' in obj:
                    with BookmarkAccess(obj['bookmarks'], paths):
                        await self.send(obj['peer'],paths,obj.get('peer_label'),obj.get('request_id'))
                elif os.environ.get('ANDROP_SANDBOXED') == '1':
                    raise ValueError('File access is unavailable')
                else:
                    await self.send(obj['peer'],paths,obj.get('peer_label'),obj.get('request_id'))
            elif command=='cancel' and obj.get('id') in self.outgoing:
                s=self.outgoing[obj['id']];s['cancel_requested']=True
                task=s.get('task')
                if task:
                    task.cancel();await asyncio.gather(task,return_exceptions=True)
            elif command=='cancel' and self.session and self.session['id']==obj.get('id'):
                s=self.session;s['cancel_requested']=True
                if s.get('protocol')=='huawei':
                    self.huawei.cancel_receive()
                    if s.get('task'):
                        s['task'].cancel();await asyncio.gather(s['task'],return_exceptions=True)
                    return
                if s.get('task'):
                    task=s['task'];task.cancel();await asyncio.gather(task,return_exceptions=True)
                    if self.session is s:
                        udp=s.pop('route_udp',None)
                        if udp:udp.close()
                        self.notify('cancel',s.get('central'));self.update(s,'cancelled');await self.reset(s)
                else:
                    future=self.decisions.get(s['id'])
                    if future and not future.done():future.set_result(False)
                    else:self.notify('cancel',s.get('central'));self.update(s,'cancelled');await self.reset(s)
        except Exception as e:
            if obj.get('command') in ('send','cancel'):
                if obj.get('command')=='send' and ('bookmarks' in obj or os.environ.get('ANDROP_SANDBOXED')=='1'):
                    try:identifier=uuid.UUID(obj.get('request_id','')).hex
                    except (ValueError,TypeError,AttributeError):identifier=None
                    if identifier and identifier not in self.outgoing:
                        self.update({'id':identifier,'direction':'send','peer':obj.get('peer_label','Android')},'failed',
                                    detail=t('Choose the files again to allow access.','请重新选择文件，以允许访问。'))
                # An invalid request must not cancel a different destination.
                emit('error',detail=t('Could not process the transfer request.','无法处理传输请求。'));return
            if obj.get('command')=='write' and self.session and obj.get('central')!=self.session.get('central'):
                emit('diagnostic',detail='ignored_unrelated_invalid_write');return
            if self.session:
                s=self.session;self.notify('cancel',s.get('central'));self.update(s,'failed',detail=transfer_error_detail(e,receiving=s.get('direction')=='receive'));await self.reset(s)
            else:emit('error',detail=str(e))
    async def run(self):
        loop=asyncio.get_running_loop();main_task=asyncio.current_task()
        loop.add_signal_handler(signal.SIGTERM,main_task.cancel)
        self.read_state();self.launch(self.scanning());self.launch(self.huawei.run());emit('ready')
        reader=asyncio.StreamReader(limit=1048576);protocol=asyncio.StreamReaderProtocol(reader)
        await asyncio.get_running_loop().connect_read_pipe(lambda:protocol,sys.stdin)
        try:
            while line:=await reader.readline():
                try:self.launch(self.command(json.loads(line)))
                except Exception:emit('error',detail='Invalid app command')
        finally:
            self.huawei.cancel()
            for task in list(self.jobs):task.cancel()
            await asyncio.gather(*self.jobs,return_exceptions=True)
            if self.destination_access: self.destination_access.close()
            loop.remove_signal_handler(signal.SIGTERM)

if __name__=='__main__':
    sys.modules.setdefault('engine',sys.modules[__name__])
    os.umask(0o077)
    if sys.argv[1:2]==['--huawei-send']:
        from huawei_runtime import send_worker
        send_worker()
    elif sys.argv[1:2]==['--huawei-check']:
        from huawei_runtime import runtime_check
        runtime_check()
    elif sys.argv[1:2]==['--live-photo-check']:
        import subprocess
        from motion_photos import helper_path
        probe=subprocess.run([str(helper_path())],capture_output=True,timeout=10)
        if probe.returncode==0 or probe.stderr!=b'invalid_arguments\n':
            raise RuntimeError('Live Photo helper packaging check failed')
        print('Live Photo helper packaging check passed')
    else:asyncio.run(Engine().run())
