# SPDX-License-Identifier: GPL-3.0-only
"""Huawei Share adapter for anDrop's approval, progress and history events.

The native host supplies UDP datagram boundaries and the kernel source address.
Advertisements select an endpoint, never establish permanent peer trust.
"""
import asyncio
import base64
import hashlib
import importlib.util
import ipaddress
import json
import os
from pathlib import Path
import secrets
import shutil
import signal
import subprocess
import struct
import sys
import tempfile
import threading
import time
import uuid
from network_routes import interfaces, private_ipv4
from motion_photos import prepare_send, materialize_received

# This Mac's own Huawei Share name (RSA-2048, owner-only). Phones remember it
# after a transfer, which "Visible to devices shared with" requires. It is not
# a credential for any phone and never makes a phone trusted.
IDENTITY = Path.home() / 'Library/Application Support/anDrop/Huawei/identity.pem'
SHARE_CAPABILITY = 256  # OpenHarmony DSoftBus capability bit 8 (share).
DEVICE_KINDS = {12: 'computer', 14: 'phone', 17: 'tablet'}  # DSoftBus TYPE_PC_ID / TYPE_PHONE_ID / TYPE_PAD_ID.
# Fixed diagnostic codes; the native diagnostics store drops free-form text.
REJECTION_CODES = (('discovery source', 'discovery_address'), ('invalid CoAP', 'discovery_coap'),
                   ('unsupported discovery message', 'discovery_coap'), ('truncated discovery option', 'discovery_coap'),
                   ('unsupported discovery resource', 'discovery_resource'), ('discovery address or business', 'discovery_address'),
                   ('not a Huawei Share discovery record', 'discovery_record'), ('invalid discovery service data', 'discovery_port'),
                   ('invalid or ambiguous discovery port', 'discovery_port'), ('invalid discovery identity', 'discovery_identity'))


def receive_error_phase(error):
    # Only fixed local messages become fixed tokens; never log remote metadata,
    # file paths, exception text or thumbnails in the public diagnostic report.
    message = str(error)
    groups = {
        'receive_preview': ('unsupported batch preview', 'unsupported fixture preview', 'repeated fixture preview'),
        'receive_preview_frame': ('unsupported byte data frame', 'byte data integrity failed', 'byte data deadline', 'byte data connection closed'),
        'receive_metadata': ('batch count mismatch', 'truncated batch metadata', 'truncated batch filename',
                             'batch file ID mismatch', 'duplicate batch filename', 'invalid single file basename',
                             'incoming file exceeds 8 MiB', 'batch file ID changed', 'duplicate batch basename',
                             'batch metadata total differs from accepted offer'),
        'receive_data': ('short batch DATA', 'unexpected batch DATA file ID', 'batch DATA size exceeded',
                         'batch DATA flag mismatch', 'unsupported fixture data framing', 'unexpected fixture sequence',
                         'fixture data integrity failed', 'fixture authenticated header differs'),
    }
    return next((phase for phase, messages in groups.items() if message in messages), 'receive')


def receive_failure_site(error):
    """Only a known local module and source line; no paths, locals or messages."""
    modules = {'huawei-receive-channels.py': 'channels', 'huawei-file-batch.py': 'batch',
               'huawei-transfer-probe.py': 'transfer', 'huawei-auth-probe.py': 'auth',
               'huawei-receive-probe.py': 'offer', 'huawei_runtime.py': 'runtime'}
    site = {}
    trace = error.__traceback__
    while trace is not None:
        module = modules.get(Path(trace.tb_frame.f_code.co_filename).name)
        if module is not None and 1 <= trace.tb_lineno <= 10000:
            site = {'receive_module': module, 'receive_line': trace.tb_lineno}
        trace = trace.tb_next
    return site


def preview_diagnostics(result):
    """Export only bounded numeric framing, never preview payloads or names."""
    output = {}
    if result.get('preview_issue') in ('field_layout', 'name_size', 'thumbnail_size', 'metadata_size', 'repeated_preview'):
        output['preview_issue'] = result['preview_issue']
    frames = result.get('byte_data', [])
    if not isinstance(frames, list) or not frames or not isinstance(frames[-1], dict):
        return output
    commands = frames[-1].get('tlvs', [])
    if not isinstance(commands, list) or len(commands) != 1 or not isinstance(commands[0], dict) or commands[0].get('tag') != 8:
        return output
    fields = commands[0].get('fields')
    if (isinstance(fields, list) and len(fields) <= 32
            and all(isinstance(f, dict) and type(f.get('tag')) is int and 0 <= f['tag'] <= 255
                    and type(f.get('bytes')) is int and 0 <= f['bytes'] <= 1024 * 1024 for f in fields)):
        output['preview_fields'] = [{'tag': f['tag'], 'bytes': f['bytes']} for f in fields]
    return output


def protocol(name):
    root = Path(sys._MEIPASS) / 'huawei' if getattr(sys, 'frozen', False) else Path(__file__).resolve().parents[1] / 'scripts'
    spec = importlib.util.spec_from_file_location('androp_' + name.replace('-', '_'), root / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def unique_json(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError('duplicate discovery field')
        value[key] = item
    return value


def decode_advertisement(data, host, local):
    """Parse one complete CoAP datagram; never scan arbitrary bytes for JSON."""
    if not private_ipv4(host) or ipaddress.ip_address(host) not in local.network or host == local.address:
        raise ValueError('discovery source is not on selected LAN')
    if not 4 <= len(data) <= 8192 or data[0] >> 6 != 1 or data[0] & 15 > 8:
        raise ValueError('invalid CoAP header')
    message_type, token_size = (data[0] >> 4) & 3, data[0] & 15
    confirmable = message_type == 0
    if message_type not in (0, 1) or data[1] != 2 or 4 + token_size > len(data):
        raise ValueError('unsupported discovery message')
    offset, number, options = 4 + token_size, 0, []
    def extended(nibble):
        nonlocal offset
        if nibble < 13:
            return nibble
        count = 1 if nibble == 13 else 2 if nibble == 14 else 0
        if not count or offset + count > len(data):
            raise ValueError('invalid CoAP option length')
        value = int.from_bytes(data[offset:offset + count], 'big') + (13 if count == 1 else 269)
        offset += count
        return value
    while offset < len(data) and data[offset] != 255:
        initial = data[offset]; offset += 1
        number += extended(initial >> 4)
        length = extended(initial & 15)
        if offset + length > len(data) or len(options) >= 16:
            raise ValueError('truncated discovery option')
        options.append((number, data[offset:offset + length])); offset += length
    # HarmonyOS sends Uri-Host + Uri-Path with no Content-Format. Its Uri-Host
    # must remain bound to this LAN pair; never use it as a connection target.
    uri_hosts = (local.address.encode(), host.encode(), str(local.network.broadcast_address).encode(), b'224.0.0.1')
    valid = (len({n for n, _ in options}) == len(options)
             and dict(options).get(11) == b'device_discover'
             and all(n in (3, 11, 12) for n, _ in options)
             and dict(options).get(3, local.address.encode()) in uri_hosts
             and dict(options).get(12, b'2') == b'2')
    if not valid or offset >= len(data) - 1:
        shape = ','.join(f'{n}:{len(v)}' for n, v in options)
        shape += f';path={dict(options).get(11) == b"device_discover"};host={dict(options).get(3, local.address.encode()) in uri_hosts};format={dict(options).get(12, b"2") == b"2"}'
        raise ValueError('unsupported discovery resource:' + shape)
    payload = data[offset + 1:]
    # Native SoftBus serializes a terminating C NUL inside the CoAP payload.
    # Accept exactly that terminator, never a second record or trailing data.
    if payload.endswith(b'\0'):
        payload = payload[:-1]
    value = json.loads(payload.decode('utf-8'), object_pairs_hook=unique_json)
    if not isinstance(value, dict) or value.get('wlanIp') != host or value.get('bType') != 5:
        raise ValueError('discovery address or business mismatch')
    caps = value.get('capabilityBitmap')
    kind = DEVICE_KINDS.get(value['type'], 'unknown') if type(value.get('type')) is int else 'unknown'
    # An idle HarmonyOS 7 phone answers discovery without the SHARE bit, yet
    # accepts Huawei Share on its advertised port. Other types must advertise it.
    if (not isinstance(caps, list) or not 1 <= len(caps) <= 4 or any(type(v) is not int or not 0 <= v < 2**32 for v in caps)
            or not (caps[0] & SHARE_CAPABILITY or kind in ('phone', 'tablet'))
            or type(value.get('mode')) is not int or value['mode'] not in (0, 1, 2, 10)):
        mode = value.get('mode')
        shape = f'mode={mode}' if type(mode) is int and 0 <= mode <= 255 else 'mode=invalid'
        if isinstance(caps, list) and len(caps) <= 4 and all(type(v) is int and 0 <= v < 2**32 for v in caps):
            shape += ';caps=' + ','.join(str(v) for v in caps)
        raise ValueError('not a Huawei Share discovery record:' + shape)
    service = value.get('serviceData')
    if not isinstance(service, str) or len(service) > 256:
        raise ValueError('invalid discovery service data')
    ports = [item[5:] for item in service.split(',') if item.startswith('port:')]
    if len(ports) != 1 or not ports[0].isascii() or not ports[0].isdigit() or not 1 <= int(ports[0]) <= 65535:
        raise ValueError('invalid or ambiguous discovery port')
    identity = value.get('deviceId')
    name = value.get('devicename', 'Huawei')
    if not isinstance(identity, str) or not 1 <= len(identity) <= 512 or not isinstance(name, str) or not 1 <= len(name) <= 100 or any(ord(c) < 32 for c in name):
        raise ValueError('invalid discovery identity metadata')
    # Ephemeral routing ID only: never feed this into anDrop's trusted-device IDs.
    identifier = 'huawei:' + hashlib.sha256((host + '\0' + identity).encode()).hexdigest()
    # PC + osType:2 is the Apple compatibility advertisement already emitted
    # by anDrop and Petal. Transport is not manufacturer identity. Use this
    # optional, self-reported hint only for display, never for peer trust.
    extension = value.get('extendServiceData')
    os_types = []
    if isinstance(extension, str) and len(extension) <= 256:
        os_types = [item.partition(':')[2] for item in extension.split(',') if item.partition(':')[0] == 'osType']
    brand = 'Apple' if kind == 'computer' and os_types == ['2'] else 'Huawei'
    return {'id': identifier, 'host': host, 'port': int(ports[0]), 'name': name, 'brand': brand,
            'kind': kind, 'last': time.monotonic()}, confirmable, data[2:4]


def advertisement(local, port, identity, name, discovering=False):
    value = {'deviceId': json.dumps({'UDID': identity}, separators=(',', ':')), 'devicename': name[:60],
             'type': 12, 'hicomversion': '', 'mode': 1 if discovering else 10, 'deviceHash': '',
             'serviceData': f'port:{port},', 'extendServiceData': 'osType:2,nbVer:9,rssi:-58,abl:8',
             'wlanIp': local, 'capabilityBitmap': [256], 'bType': 5, 'seqNo': secrets.randbelow(65536)}
    if discovering:
        value['coapUri'] = f'coap://{local}:5684/device_discover'
    return b'\x42\x02' + secrets.token_bytes(4) + b'\xbd\x02device_discover\x11\x32\xff' + json.dumps(value, separators=(',', ':')).encode()


def place_exclusive(source, destination):
    """Darwin atomic rename with RENAME_EXCL; an existing target always wins."""
    import ctypes
    libc = ctypes.CDLL(None, use_errno=True)
    rename = libc.renamex_np
    rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    if rename(os.fsencode(source), os.fsencode(destination), 0x00000004) != 0:
        raise OSError(ctypes.get_errno(), 'could not place received file')


def publish_files(staging, destination, stopped=None):
    """Move completed files directly into Downloads, retaining existing names."""
    destination = Path(destination).resolve(strict=True)
    if not destination.is_dir():
        raise ValueError('save folder unavailable')
    saved = []
    try:
        for path in sorted(staging.iterdir()):
            if stopped is not None and stopped.is_set():
                raise ValueError('receive cancelled')
            if not path.is_file() or path.is_symlink():
                raise ValueError('invalid staged receive file')
            data = path.read_bytes()
            # Same quarantine semantics as the existing archive receiver.
            import ctypes
            libc = ctypes.CDLL(None, use_errno=True)
            setter = libc.setxattr
            setter.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]
            attribute = f'0083;{int(time.time()):x};anDrop;'.encode()
            if setter(os.fsencode(path), b'com.apple.quarantine', attribute, len(attribute), 0, 0) != 0:
                raise OSError(ctypes.get_errno(), 'could not mark received file')
            for attempt in range(10000):
                if stopped is not None and stopped.is_set():
                    raise ValueError('receive cancelled')
                target = destination / (path.name if not attempt else f'{path.stem} ({attempt}){path.suffix}')
                try:
                    place_exclusive(path, target)
                    break
                except FileExistsError:
                    continue
            else:
                raise ValueError('too many filename collisions')
            saved.append({'path': str(target), 'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()})
        return saved
    except BaseException:
        for item in saved:
            Path(item['path']).unlink(missing_ok=True)
        raise


STAGING_PREFIX = '.anDrop-Huawei-'
# Protocol modules report transport loss as ValueError with these markers.
CONNECTION_MARKERS = ('deadline', 'closed', 'incomplete frame')


def connection_lost(error_type, reason=''):
    return (error_type in ('BrokenPipeError', 'ConnectionResetError', 'ConnectionAbortedError')
            or (error_type == 'ValueError' and any(marker in reason for marker in CONNECTION_MARKERS)))


def error_detail(error, receiving):
    from engine import transfer_error_detail, t
    if connection_lost(type(error).__name__, str(error)):
        return t('The connection to the phone was interrupted. Keep both devices on the same Wi-Fi and try again.',
                 '与手机的连接已中断。请让两台设备保持连接同一 Wi-Fi 后重试。')
    if str(error) == 'phone cancelled transfer':
        return t('The phone cancelled the transfer.', '对方已取消传输。')
    return transfer_error_detail(error, receiving=receiving)


def remove_stale_staging(destination, age=600):
    """Delete staging left by a killed engine. Receives end within 90 s, so an
    old directory with our private prefix is never in use."""
    removed = 0
    for path in Path(destination).glob(STAGING_PREFIX + '*'):
        try:
            info = path.lstat()
            if (path.is_symlink() or not path.is_dir() or info.st_uid != os.getuid()
                    or time.time() - info.st_mtime < age):
                continue
            shutil.rmtree(path)
            removed += 1
        except OSError:
            continue
    return removed


class Processes(list):
    def __init__(self):
        super().__init__(); self.stopped = threading.Event(); self.groups = set()
    def append_group(self, child):
        self.groups.add(child.pid)
        self.append(child)
    def append(self, child):
        super().append(child)
        if self.stopped.is_set() and child.poll() is None:
            child.terminate()
    def stop(self):
        self.stopped.set()
        for child in list(self):
            if child.poll() is None:
                try:
                    if child.pid in self.groups: os.killpg(child.pid, signal.SIGTERM)
                    else: child.terminate()
                except (ProcessLookupError, PermissionError):
                    # Darwin reports EPERM for a group whose only member is an
                    # unreaped zombie: the worker has already finished.
                    pass
    def close(self):
        self.stop()
        for child in self:
            try:
                child.wait(timeout=2)
            except subprocess.TimeoutExpired:
                child.kill(); child.wait()
            for stream in (child.stdin, child.stdout):
                if stream:
                    try: stream.close()
                    except OSError: pass


class HuaweiRuntime:
    def __init__(self, engine, emit):
        self.engine, self.emit = engine, emit
        self.peers = {}; self.local = None; self.listener = None; self.children = None
        self.private = None; self.identity = ''; self.node_id = None; self.active = None; self.enabled = False
        self.senders = {}
        self.identity_path = IDENTITY; self.persistent = False
        self.loop = None
        self.responses = {}
        self.last_rejection = 0
    def datagram(self, obj):
        if not self.enabled or self.local is None or obj.get('local') != self.local.address or obj.get('port') != 5684:
            return
        try:
            data = b''
            data = base64.b64decode(obj.get('data', ''), validate=True)
            peer, confirmable, message_id = decode_advertisement(data, obj.get('host'), self.local)
        except (ValueError, TypeError, KeyError, RecursionError) as error:
            # Bare 4-byte CoAP ACKs answer our own confirmable datagrams.
            if len(data) > 4 and time.monotonic() - self.last_rejection >= 2:
                self.last_rejection = time.monotonic()
                code = next((c for prefix, c in REJECTION_CODES if str(error).startswith(prefix)), 'malformed')
                self.emit('diagnostic', detail='huawei_discovery_rejected', phase=code, error_type=type(error).__name__)
            return
        previous = self.peers.get(peer['id'])
        self.peers[peer['id']] = peer
        if previous is None or previous['port'] != peer['port']:
            self.emit('diagnostic', detail='huawei_peer_discovered', phase='discovery')
        if len(self.peers) > 64:
            self.peers.pop(min(self.peers, key=lambda k: self.peers[k]['last']))
        if confirmable:
            self.send_datagram(peer['host'], b'\x60\x00' + message_id)
        if time.monotonic() - self.responses.get(peer['host'], 0) >= 2:
            self.responses[peer['host']] = time.monotonic()
            if len(self.responses) > 64:
                self.responses.pop(min(self.responses, key=self.responses.get))
            # Always answer as a receiver (PUBLISH_MODE_PROACTIVE): phones do not
            # list a mode-1 discoverer, even while our own recipient picker is open.
            self.send_datagram(peer['host'], self.packet(discovering=False))
        if self.engine.discovering:
            self.engine.publish_peers()
    def send_datagram(self, host, data):
        self.emit('huawei_datagram', host=host, data=base64.b64encode(data).decode())
    def packet(self, discovering=None):
        discovering = self.engine.discovering if discovering is None else discovering
        return advertisement(self.local.address, self.port, self.identity, self.engine.name, discovering)
    def visible_peers(self):
        now = time.monotonic()
        self.peers = {k: p for k, p in self.peers.items() if now - p['last'] < 10}
        return [{k: p[k] for k in ('id', 'name', 'brand', 'kind')} for p in self.peers.values()]
    def cancel(self):
        self.cancel_receive()
        for children in self.senders.values():
            children.stop()
    def cancel_receive(self):
        if self.active:
            self.active.stop()
        session = self.engine.session
        if session and session.get('protocol') == 'huawei':
            future = self.engine.decisions.get(session['id'])
            if future is not None and not future.done(): future.set_result(False)
    async def run(self):
        self.loop = asyncio.get_running_loop()
        retry_delay = 1
        failure_reported = False
        try:
            while True:
                try:
                    allowed = self.engine.huawei_enabled
                    addresses = await asyncio.to_thread(interfaces)
                    current = next((a for a in addresses if a.interface == 'en0'), None)
                    if not allowed or current is None or (self.local and self.local.address != current.address):
                        self.enabled = False
                        self.emit('huawei_discovery', enabled=False)
                        if self.children: self.children.close()
                        self.children = self.listener = None
                        if self.active or self.senders: self.cancel()
                        self.local = current
                        await asyncio.sleep(1)
                        continue
                    self.local = current
                    if self.listener is None:
                        await self.open_listener()
                    self.enabled = True
                    self.emit('huawei_discovery', enabled=True)
                    if not self.engine.busy:
                        self.send_datagram('broadcast', self.packet())
                        self.send_datagram('multicast', self.packet())
                    if self.listener and self.listener.stdout and await asyncio.to_thread(self.readable):
                        selected = self.listener
                        self.listener = None
                        children = self.children
                        self.children = None
                        task = self.engine.launch(self.receive(selected, children))
                        await asyncio.gather(task, return_exceptions=True)
                    if self.engine.discovering:
                        self.engine.publish_peers()
                    retry_delay = 1
                    failure_reported = False
                except (OSError, subprocess.SubprocessError) as error:
                    # A transient interface/listener failure must not disable
                    # Huawei discovery until the application is restarted.
                    self.enabled = False
                    if self.children: self.children.close()
                    self.children = self.listener = None
                    # Discovery is independent of an active outgoing transfer.
                    # A failed interface query must not kill its worker or approval.
                    if not failure_reported:
                        self.emit('diagnostic', detail='huawei_runtime_stopped',
                                  error_type='TimeoutError' if isinstance(error, subprocess.TimeoutExpired) else 'OSError')
                        self.emit('huawei_discovery', enabled=False)
                        failure_reported = True
                    await asyncio.sleep(retry_delay)
                    retry_delay = min(30, retry_delay * 2)
                    continue
                await asyncio.sleep(1)
        except asyncio.CancelledError:
            raise
        except Exception as error:
            self.emit('diagnostic', detail='huawei_runtime_stopped', error_type=type(error).__name__)
        finally:
            # Stop listeners before reporting: the host pipe may already be gone
            # (BrokenPipeError), which must not leave an orphaned nc listener.
            self.enabled = False
            self.cancel()
            if self.children: self.children.close()
            self.children = self.listener = None
            try:
                self.emit('huawei_discovery', enabled=False)
            except (BrokenPipeError, ValueError, OSError):
                pass
    def readable(self):
        import select
        return bool(select.select([self.listener.stdout], [], [], .1)[0])
    async def open_listener(self):
        import socket
        from cryptography.hazmat.primitives.asymmetric import rsa
        from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
        self.receiver = protocol('huawei-receive-probe')
        self.channels = protocol('huawei-receive-channels')
        if self.private is None:
            try:
                self.private = await asyncio.to_thread(self.receiver.auth.load_identity_key, self.identity_path)
                self.persistent = True
            except (OSError, ValueError, TypeError) as error:
                # Still usable with Everyone visibility; phones just forget this Mac.
                self.emit('diagnostic', detail='huawei_identity_unavailable', error_type=type(error).__name__)
                self.private = await asyncio.to_thread(rsa.generate_private_key, public_exponent=65537, key_size=2048)
                self.persistent = False
        public = self.private.public_key().public_bytes(Encoding.DER, PublicFormat.SubjectPublicKeyInfo)
        self.identity = self.receiver.auth.protocol_v2_identity(public)
        self.node_id = self.receiver.auth.meta_node_id(public)
        with socket.socket() as reservation:
            reservation.bind((self.local.address, 0)); self.port = reservation.getsockname()[1]
        self.children = Processes()
        self.listener = subprocess.Popen(['/usr/bin/nc', '-l', self.local.address, str(self.port)], stdin=subprocess.PIPE,
                                         stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        self.children.append(self.listener)
    async def approval(self, session, result):
        if self.engine.busy or not self.engine.huawei_enabled:
            return False
        session['count'] = result['accepted_file_count']
        self.engine.session = session; self.engine.read_state()
        return await self.engine.approve_receive(session, {'totalSize': result['accepted_total_bytes'], 'fileName': 'Files'})
    async def receive(self, process, children):
        # Kernel TCP source must be a currently discovered LAN peer; payload fields
        # cannot redirect this session to a different host.
        connection = await asyncio.to_thread(subprocess.run,
            ['/usr/sbin/lsof', '-nP', '-a', '-p', str(process.pid), '-iTCP', '-sTCP:ESTABLISHED', '-Fn'],
            capture_output=True, text=True, timeout=3)
        hosts = [line.split('->', 1)[1].rsplit(':', 1)[0] for line in connection.stdout.splitlines() if line.startswith('n') and '->' in line]
        self.visible_peers()
        candidates = [p for p in self.peers.values() if hosts == [p['host']]]
        if not candidates or self.engine.busy:
            self.emit('diagnostic', detail='huawei_incoming_rejected', phase='busy' if self.engine.busy else 'undiscovered_peer')
            children.close(); return
        peer = max(candidates, key=lambda p: p['last'])
        session = {'id': uuid.uuid4().hex, 'direction': 'receive', 'peer': peer['name'], 'brand': peer['brand'],
                   'kind': peer['kind'], 'central': '', 'protocol': 'huawei'}
        session['task'] = asyncio.current_task()
        self.active = children
        result = {}
        def save():
            amount = result.get('received_progress_bytes', 0)
            def progress():
                if self.engine.session is session and not children.stopped.is_set():
                    self.engine.progress(session, amount, result.get('accepted_total_bytes', 0))
            self.loop.call_soon_threadsafe(progress)
        def approve():
            if children.stopped.is_set(): return False
            return asyncio.run_coroutine_threadsafe(self.approval(session, result), self.loop).result(timeout=30)
        def worker(folder):
            t = self.receiver.transfer
            raw = t.auth.read_frame(process, 4)
            def receive_files(device_hash, key):
                batch = t.batch_files.IncomingBatch(result['accepted_file_count'], result['accepted_total_bytes'])
                self.channels.receive(t, process, device_hash, key, self.local.address, peer['host'], children,
                    Path(folder) / 'staging', result, save, batch, publish_files=lambda staging, _: publish_files(staging, destination, children.stopped),
                    display_name=self.engine.name, node_id=self.node_id)
            self.receiver.inspect_offer(process, raw, result, save, private=self.private, receive=receive_files,
                                        accept_bounded_files=True, approve=approve,
                                        identify=lambda public: session.update(device_identifier='huawei-key:' + hashlib.sha256(public).hexdigest()))
        try:
            def prepare():
                # Folder access can block (privacy prompt, slow volume); a blocked
                # event loop would also stop discovery and the native UI commands.
                target = Path(self.engine.destination).resolve(strict=True)
                if shutil.disk_usage(target).free < 32 * 1024 * 1024:
                    raise OSError(28, 'insufficient space')
                remove_stale_staging(target)
                return target, tempfile.mkdtemp(prefix=STAGING_PREFIX, dir=target)
            destination, folder = await asyncio.to_thread(prepare)
            try:
                work = asyncio.create_task(asyncio.to_thread(worker, folder))
                try:
                    await asyncio.shield(work)
                except asyncio.CancelledError:
                    self.cancel_receive()
                    await asyncio.gather(work, return_exceptions=True)
                    raise
            finally:
                await asyncio.to_thread(shutil.rmtree, folder, True)
            if self.engine.session is session:
                if result.get('dfile_done_ack_verified'):
                    files = await materialize_received(result['saved_files'],
                        lambda code: self.emit('diagnostic', detail=code, transfer_id=session['id']))
                    self.engine.complete_received_files(session, files, result['accepted_file_count'], result['accepted_total_bytes'])
                elif result.get('inspection_offer_rejected'):
                    self.engine.update(session, 'declined')
                else:
                    raise ValueError('Huawei transfer completion was not acknowledged')
        except asyncio.CancelledError:
            self.cancel_receive()
            if self.engine.session is session: self.engine.update(session, 'cancelled')
            raise
        except Exception as error:
            self.emit('diagnostic', detail='huawei_receive_failed', error_type=type(error).__name__,
                      transfer_id=session['id'], phase=receive_error_phase(error),
                      **receive_failure_site(error), **preview_diagnostics(result))
            if self.engine.session is session:
                self.engine.update(session, 'failed', detail=error_detail(error, receiving=True), files=result.get('saved_files', []))
        finally:
            children.close(); self.active = None
            await self.engine.reset(session)

    async def send(self, peer_id, paths, label, request_id):
        from engine import transfer_error_detail, t, TransferError
        session = {'id': uuid.UUID(request_id).hex if request_id else uuid.uuid4().hex, 'direction': 'send',
                   'peer': label or 'Huawei', 'brand': 'Huawei', 'protocol': 'huawei'}
        self.visible_peers(); peer = self.peers.get(peer_id)
        if peer:
            session.update(brand=peer['brand'], kind=peer['kind'])
        if not self.engine.huawei_enabled or not self.engine.discovering or not peer:
            self.engine.update(session, 'failed', detail=t('This device is no longer available. Open Huawei Share and choose it again.',
                                                         '此设备已不可用。请打开华为分享后重新选择。')); return
        if not self.engine.start_outgoing(session, peer_id):
            self.engine.update(session, 'failed', detail=t('This device or the receiver is busy. Please try again shortly.',
                                                         '此设备或接收服务正忙，请稍后重试。')); return
        children = Processes(); self.senders[session['id']] = children
        state = {}
        try:
            self.engine.update(session, 'preparing', count=len(paths))
            with tempfile.TemporaryDirectory(prefix='anDrop-Huawei-send-') as folder:
                paths = await prepare_send(paths, Path(folder) / 'live-photos', target='huawei')
                output = Path(folder) / 'state.json'
                snapshots = Path(folder) / 'files'
                snapshots.mkdir(mode=0o700)
                preparation = asyncio.create_task(asyncio.to_thread(
                    protocol('huawei-transfer-probe').batch_files.Batch.from_paths,
                    [Path(p) for p in paths], snapshot_dir=snapshots, stopped=children.stopped))
                try:
                    batch = await asyncio.shield(preparation)
                except asyncio.CancelledError:
                    # Stop and join the copier before removing its private directory.
                    children.stop()
                    try: await preparation
                    except Exception: pass
                    raise
                except ValueError:
                    raise TransferError(t('Choose up to 16 files for Huawei Share: 4 GiB per file and 16 GiB total. Folders, links and duplicate names are not supported yet.',
                                          '华为分享最多支持 16 个文件，单个 4 GiB、合计 16 GiB。暂不支持文件夹、链接及同名文件。')) from None
                snapshot_paths = [entry.path for entry in batch.entries]
                self.engine.update(session, 'preparing', count=batch.count, total=batch.size, name=batch.name.decode('utf-8'))
                command = ([sys.executable, '--huawei-send'] if getattr(sys, 'frozen', False) else [sys.executable, str(Path(__file__).with_name('engine.py')), '--huawei-send'])
                command += ['--peer-ip', peer['host'], '--port', str(peer['port']), '--network-lan', '--seconds', '60',
                            '--display-name', self.engine.name, '--output', str(output)]
                if self.persistent: command += ['--identity-key', str(self.identity_path)]
                for path in snapshot_paths: command += ['--send-file', str(path)]
                child = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                         start_new_session=True)
                children.append_group(child)
                self.engine.update(session, 'waiting', count=batch.count, total=batch.size)
                while child.poll() is None:
                    if output.exists():
                        try: state = json.loads(output.read_text())
                        except ValueError: pass
                        if state.get('receiver_accepted'):
                            self.engine.progress(session, state.get('data_bytes_queued', 0), batch.size)
                    try:
                        await asyncio.sleep(.2)
                    except asyncio.CancelledError:
                        # A cancel can race the phone's final DONE; read the last state first.
                        try: state = json.loads(output.read_text())
                        except (OSError, ValueError): pass
                        raise
                if output.exists(): state = json.loads(output.read_text())
                if state.get('status') == 'receiver_declined_or_cancelled':
                    # Phones set to "devices shared with" reject unknown senders with no prompt.
                    raise TransferError(t('The phone cancelled the transfer.', '对方已取消传输。') if state.get('receiver_accepted') else
                                        t('The phone declined the files. For the first transfer, set Huawei Share on the phone to Everyone; later transfers work with “Devices shared with”.',
                                          '对方已拒绝接收文件。首次传输时，请在手机的华为分享中选择“所有人可见”；之后选择“仅分享过的设备可见”也可接收。'))
                if not state.get('dfile_transfer_done_received'):
                    if connection_lost(state.get('error_type', ''), state.get('error_reason', '')):
                        raise BrokenPipeError(32, 'Huawei transfer connection closed')
                    raise ValueError('Huawei transfer did not complete')
                self.engine.update(session, 'complete', count=batch.count, total=batch.size, completed=batch.size)
        except asyncio.CancelledError:
            children.stop()
            if state.get('dfile_transfer_done_received'):
                # The phone already acknowledged every file: cancelling came too late.
                self.engine.update(session, 'complete', count=state.get('file_count'), total=state.get('total_bytes'),
                                   completed=state.get('total_bytes'))
            else:
                self.engine.update(session, 'cancelled')
            raise
        except Exception as error:
            self.emit('diagnostic', detail='huawei_send_failed', error_type=type(error).__name__)
            self.engine.update(session, 'failed', detail=error_detail(error, receiving=False))
        finally:
            try:
                children.close()
            finally:
                self.senders.pop(session['id'], None)
                await self.engine.reset(session)


def send_worker():
    sys.argv = [sys.argv[0], *sys.argv[2:]]
    protocol('huawei-transfer-probe').main()


def runtime_check():
    """Packaging check with no network or filesystem mutations."""
    transfer = protocol('huawei-transfer-probe')
    protocol('huawei-receive-probe')
    protocol('huawei-receive-channels')
    key, body = b'k' * 32, b'anDrop packaging check'
    packet = transfer.encrypted_frame(b'0' * 16, key, body, 0)
    if transfer.decrypt_frame(packet, key) != body:
        raise RuntimeError('Huawei crypto packaging check failed')
    framing = protocol('huawei-receive-channels')
    chunk = transfer.dfile_data_chunk(key, body, 16384, 3)
    if framing.decrypt_data_chunk(key, struct.unpack_from('!BBHHH', chunk)[:4], chunk[8:], 16384) != body:
        raise RuntimeError('Huawei large-file packaging check failed')
    # Persistent identity PEM round trip, in memory only.
    from cryptography.hazmat.primitives.asymmetric import rsa
    from cryptography.hazmat.primitives.serialization import (Encoding, NoEncryption, PrivateFormat, PublicFormat,
                                                              load_pem_private_key)
    identity = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    pem = identity.private_bytes(Encoding.PEM, PrivateFormat.PKCS8, NoEncryption())
    public = load_pem_private_key(pem, password=None).public_key().public_bytes(Encoding.DER, PublicFormat.SubjectPublicKeyInfo)
    if len(transfer.auth.meta_node_id(public)) != 64 or len(transfer.auth.protocol_v2_identity(public)) != 12:
        raise RuntimeError('Huawei identity packaging check failed')
    print(json.dumps({'huawei_runtime_check': 'passed',
                      'send_max_file_bytes': transfer.batch_files.MAX_SEND_FILE,
                      'send_max_total_bytes': transfer.batch_files.MAX_SEND_TOTAL}), flush=True)
