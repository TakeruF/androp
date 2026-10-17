"""Bounded explicitly selected files for the experimental Huawei LAN probes."""
import hashlib
from collections import deque
from contextlib import ExitStack
import errno
import os
from pathlib import Path
import select
import stat
import struct
import time
import unicodedata

MAX_FILE = 8 * 1024 * 1024
MAX_TOTAL = 16 * 1024 * 1024
MAX_RECEIVE_FILE = MAX_TOTAL
MAX_FILES = 16
MAX_SEND_FILE = 4 * 1024 ** 3
MAX_SEND_TOTAL = 16 * 1024 ** 3
COPY_CHUNK = 1024 * 1024


def safe_name(name):
    text = name.decode('utf-8', errors='strict')
    if (not 1 <= len(name) <= 255 or text in ('.', '..') or text.endswith((' ', '.'))
            or any(c in text for c in '/\\:\0') or any(ord(c) < 32 for c in text)):
        raise ValueError('invalid single file basename')
    return unicodedata.normalize('NFC', text).casefold()


class File:
    def __init__(self, name, content):
        safe_name(name)
        if not isinstance(content, bytes) or len(content) > MAX_FILE:
            raise ValueError('file exceeds 8 MiB')
        self.name, self.content = name, content
        self.size = len(content)
        self.sha256 = hashlib.sha256(content).hexdigest()

    def chunks(self):
        for offset in range(0, self.size, 1422):
            yield self.content[offset:offset + 1422]


def identity(info):
    return info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns


class DiskFile:
    """A hashed file read in bounded chunks, without retaining its contents."""
    def __init__(self, path, info, digest):
        self.path, self.name = Path(path), Path(path).name.encode('utf-8')
        self.size, self.sha256, self.identity = info.st_size, digest, identity(info)

    def chunks(self):
        with ExitStack() as stack:
            fd = os.open(self.path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            stack.callback(os.close, fd)
            if identity(os.fstat(fd)) != self.identity:
                raise ValueError('source changed after snapshot')
            source = stack.enter_context(os.fdopen(fd, 'rb', closefd=False))
            digest, size = hashlib.sha256(), 0
            while chunk := source.read(1422):
                size += len(chunk)
                if size > self.size:
                    raise ValueError('source changed after snapshot')
                digest.update(chunk)
                yield chunk
            if (size != self.size or identity(os.fstat(fd)) != self.identity
                    or digest.hexdigest() != self.sha256):
                raise ValueError('source changed after snapshot')


class Batch:
    def __init__(self, entries):
        self.entries = tuple(entries)
        if not 1 <= len(self.entries) <= MAX_FILES:
            raise ValueError('select 1..16 files')
        names = [safe_name(e.name) for e in self.entries]
        if len(set(names)) != len(names):
            raise ValueError('duplicate or filesystem-equivalent basenames')
        self.size = sum(e.size for e in self.entries)
        if self.size > MAX_SEND_TOTAL:
            raise ValueError('send batch exceeds 16 GiB')
        self.count = len(self.entries)
        self.name = self.entries[0].name

    @classmethod
    def from_paths(cls, paths, *, snapshot_dir=None, stopped=None):
        if not 1 <= len(paths) <= MAX_FILES:
            raise ValueError('select 1..16 explicit paths')
        entries, total, sources, names = [], 0, [], set()
        def check_cancelled():
            if stopped is not None and stopped.is_set():
                raise ValueError('send cancelled')
        with ExitStack() as stack:
            # Check the entire selection before hashing or copying large files.
            for raw in paths:
                check_cancelled()
                path = Path(raw)
                name = safe_name(path.name.encode('utf-8'))
                if name in names:
                    raise ValueError('duplicate or filesystem-equivalent basenames')
                names.add(name)
                fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
                stack.callback(os.close, fd)
                info = os.fstat(fd)
                if not stat.S_ISREG(info.st_mode) or not 0 <= info.st_size <= MAX_SEND_FILE:
                    raise ValueError('source must be a regular file of at most 4 GiB')
                total += info.st_size
                if total > MAX_SEND_TOTAL:
                    raise ValueError('send batch exceeds 16 GiB')
                source = stack.enter_context(os.fdopen(fd, 'rb', closefd=False))
                sources.append((path, source, info))
            if snapshot_dir is not None:
                import shutil
                if shutil.disk_usage(snapshot_dir).free < total:
                    raise OSError(errno.ENOSPC, 'not enough space for send snapshot')
            for path, source, info in sources:
                check_cancelled()
                target_path = Path(snapshot_dir) / path.name if snapshot_dir is not None else path
                digest, copied = hashlib.sha256(), 0
                with ExitStack() as target_stack:
                    target = target_stack.enter_context(target_path.open('xb')) if snapshot_dir is not None else None
                    while chunk := source.read(COPY_CHUNK):
                        check_cancelled()
                        copied += len(chunk)
                        if copied > info.st_size:
                            raise ValueError('source changed during snapshot')
                        digest.update(chunk)
                        if target is not None:
                            target.write(chunk)
                    if copied != info.st_size or identity(os.fstat(source.fileno())) != identity(info):
                        raise ValueError('source changed during snapshot')
                entries.append(DiskFile(target_path, target_path.stat() if snapshot_dir is not None else info, digest.hexdigest()))
        return cls(entries)


class IncomingBatch:
    """Metadata bounds from an explicitly accepted offer, with no local reference."""
    def __init__(self, count, size):
        if type(count) is not int or type(size) is not int or not 1 <= count <= MAX_FILES or not 0 <= size <= MAX_TOTAL:
            raise ValueError('incoming batch exceeds offer limits')
        self.count, self.size = count, size
        self.entries, self.name = (), b''


class IncomingFile:
    def __init__(self, name, size):
        safe_name(name)
        if not 0 <= size <= MAX_RECEIVE_FILE:
            raise ValueError('incoming file exceeds 16 MiB')
        self.name, self.size, self.sha256 = name, size, None


def id_list(payload, count):
    if not payload or len(payload) % 2:
        raise ValueError('invalid file ID list')
    ids = list(struct.unpack('!' + 'H' * (len(payload) // 2), payload))
    if len(set(ids)) != len(ids) or any(not 1 <= i <= count for i in ids):
        raise ValueError('unknown or duplicate file ID')
    return ids


def headers(t, batch):
    payload = struct.pack('!H', batch.count)
    for file_id, entry in enumerate(batch.entries, 1):
        unit = struct.pack('!HQH', file_id, entry.size, len(entry.name)) + entry.name
        if len(payload) + len(unit) > 1400:
            yield t.dfile_packet(1, 0, 1, payload)
            payload = struct.pack('!H', batch.count)
        payload += unit
    yield t.dfile_packet(1, 0, 1, payload)


def parse_header(payload, batch):
    if len(payload) < 14 or struct.unpack_from('!H', payload)[0] != batch.count:
        raise ValueError('batch count mismatch')
    expected = {e.name: e for e in batch.entries}
    offset, entries = 2, {}
    while offset < len(payload):
        if len(payload) - offset < 12:
            raise ValueError('truncated batch metadata')
        file_id, size, length = struct.unpack_from('!HQH', payload, offset)
        offset += 12
        name = payload[offset:offset + length]
        offset += length
        if offset > len(payload):
            raise ValueError('truncated batch filename')
        if isinstance(batch, IncomingBatch):
            entry = IncomingFile(name, size)
        elif name not in expected or expected[name].size != size:
            raise ValueError('batch filename or size mismatch')
        else:
            entry = expected[name]
        if not 1 <= file_id <= batch.count or file_id in entries:
            raise ValueError('batch file ID mismatch')
        entries[file_id] = entry
    if len({e.name for e in entries.values()}) != len(entries):
        raise ValueError('duplicate batch filename')
    return entries


def send(t, process, key, batch, result, save):
    # An inactivity timeout: a healthy large transfer may take much longer.
    deadline = time.monotonic() + 60
    try:
        fd = process.stdin.fileno()
    except (AttributeError, OSError):
        fd = None
    if fd is not None:
        os.set_blocking(fd, False)
    try:
        read_fd = process.stdout.fileno()
    except (AttributeError, OSError):
        read_fd = None
    if read_fd is not None:
        os.set_blocking(read_fd, False)
    incoming, pending = bytearray(), deque()
    result['batch_control_frames'] = []
    def accept_frame(header, payload):
        kind, flags, session, transaction = header
        counts = result.setdefault('batch_control_counts', {})
        counts[str(kind)] = counts.get(str(kind), 0) + 1
        frames = result['batch_control_frames']
        if len(frames) < 128:
            frames.append({'type': kind, 'bytes': len(payload)})
        if kind == 11:
            return
        if kind not in (2, 3, 5, 6, 9) or session != 0 or transaction != 1 or flags != 0:
            raise ValueError('unexpected batch control frame')
        payload = t.dfile_decrypt_control(key, header, payload)
        if kind == 9:
            raise ValueError('peer reset batch transfer')
        # ACKs must be drained while sending, otherwise nc's stdout pipe can
        # fill and stop the socket while we wait for its stdin to accept DATA.
        if kind != 5 and (kind, payload) not in pending:
            if len(pending) >= 128:
                raise ValueError('too many pending batch controls')
            pending.append((kind, payload))
    def read_available():
        try:
            data = os.read(read_fd, 65536)
        except BlockingIOError:
            return
        if not data:
            raise ValueError('batch send connection closed')
        incoming.extend(data)
        while len(incoming) >= 8:
            kind, flags, session, transaction, size = struct.unpack_from('!BBHHH', incoming)
            if not 1 <= kind <= 14 or size > 14720:
                raise ValueError('invalid DFile framing')
            if len(incoming) < 8 + size:
                break
            payload = bytes(incoming[8:8 + size])
            del incoming[:8 + size]
            accept_frame((kind, flags, session, transaction), payload)
    def next_control():
        while not pending:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise ValueError('batch send deadline')
            if read_fd is None:
                accept_frame(*t.read_dfile_frame(process, remaining))
            elif select.select([read_fd], [], [], remaining)[0]:
                read_available()
            else:
                raise ValueError('batch send deadline')
        return pending.popleft()
    def write(packet):
        nonlocal deadline
        if fd is None:
            process.stdin.write(packet)
            process.stdin.flush()
            deadline = time.monotonic() + 60
            return
        view = memoryview(packet)
        while view:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise ValueError('batch send deadline')
            readable, writable, _ = select.select([read_fd] if read_fd is not None else [], [fd], [], remaining)
            if readable:
                read_available()
            if not writable:
                continue
            try:
                count = os.write(fd, view)
            except BlockingIOError:
                continue
            if count <= 0:
                raise ValueError('batch send pipe closed')
            view = view[count:]
            deadline = time.monotonic() + 60
    def control(kind, payload):
        write(t.dfile_encrypt_control(key, t.dfile_packet(kind, 0, 1, payload)))
    for packet in headers(t, batch):
        write(t.dfile_encrypt_control(key, packet))
    result['batch_header_sent'] = True
    sent, done = set(), set()
    last_save = time.monotonic()
    while True:
        kind, payload = next_control()
        if kind in (2, 3):
            for file_id in id_list(payload, batch.count):
                if file_id in sent:
                    continue
                entry = batch.entries[file_id - 1]
                offset = 0
                for sequence, chunk in enumerate(entry.chunks()):
                    flag = 3 if offset + len(chunk) == entry.size else (0 if sequence == 0 else 1)
                    write(t.dfile_data_chunk(key, chunk, sequence, flag, file_id=file_id))
                    offset += len(chunk)
                    result['data_bytes_queued'] = sum(batch.entries[i - 1].size for i in sent) + offset
                    now = time.monotonic()
                    if now - last_save >= .2:
                        save(); last_save = now
                sent.add(file_id)
                result['batch_file_ids_queued'] = sorted(sent)
                result['data_bytes_queued'] = sum(batch.entries[i - 1].size for i in sent)
                save()
        elif kind == 6:
            ids = set(id_list(payload, batch.count))
            if not ids <= sent:
                raise ValueError('premature batch DONE')
            done |= ids
            result['batch_file_ids_done'] = sorted(done)
            if len(done) == batch.count:
                control(7, b'')
                result.update(file_data_sent=bool(batch.size), dfile_transfer_done_received=True, dfile_done_ack_sent=True)
                save()
                return
        save()


def receive(t, framing, process, key, batch, destination, result, save, publish_files=None):
    if batch.size > MAX_TOTAL or any(entry.size > MAX_RECEIVE_FILE for entry in batch.entries):
        raise ValueError('incoming batch exceeds offer limits')
    def control(kind, transaction, payload):
        process.stdin.write(t.dfile_encrypt_control(key, t.dfile_packet(kind, 0, transaction, payload)))
        process.stdin.flush()
    def publish():
        # Every digest is checked before creating any destination. mkdir is exclusive.
        digests = {i: hashlib.sha256(contents[i]).hexdigest() for i in metadata}
        for i, entry in metadata.items():
            if entry.sha256 is not None and digests[i] != entry.sha256:
                raise ValueError('batch content digest mismatch')
        destination.mkdir(mode=0o700)
        records = []
        for i, entry in metadata.items():
            path = destination / entry.name.decode('utf-8')
            with path.open('xb') as output:
                output.write(contents[i]); output.flush(); os.fsync(output.fileno())
            if hashlib.sha256(path.read_bytes()).hexdigest() != digests[i]:
                raise ValueError('batch saved readback mismatch')
            records.append({'file_id': i, 'bytes': entry.size, 'sha256': digests[i]})
        if publish_files is not None:
            result['saved_files'] = publish_files(destination, records)
        result.update(file_received=True, saved_content_verified=True, received_files=records,
                      reference_content_verified=not isinstance(batch, IncomingBatch))
    deadline = time.monotonic() + 90
    settings = False
    transaction = None
    metadata, contents, sequences, complete = {}, {}, {}, set()
    for _ in range(32768):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise ValueError('batch receive deadline')
        header, payload = t.read_dfile_frame(process, min(5, remaining))
        kind, flags, session, trans = header
        counts = result.setdefault('dfile_frame_counts', {})
        counts[str(kind)] = counts.get(str(kind), 0) + 1
        if kind == 8 and not settings:
            if len(payload) < 100 or struct.unpack_from('!H', payload, 2)[0] != 2 or not struct.unpack_from('!I', payload, 20)[0] & 0x100 or payload[91] != 1 or not struct.unpack_from('!I', payload, 96)[0] & 1:
                raise ValueError('unsupported batch WLAN settings')
            process.stdin.write(t.dfile_settings()); process.stdin.flush()
            settings = True
        elif kind == 11:
            pass
        elif settings and result.get('preview_ack_sent') and kind == 1 and not result.get('file_received'):
            if session != 0 or flags != 0 or (transaction is not None and trans != transaction):
                raise ValueError('batch header transaction mismatch')
            transaction = trans
            part = parse_header(t.dfile_decrypt_control(key, header, payload), batch)
            for i, entry in part.items():
                if i in metadata and (metadata[i].name, metadata[i].size) != (entry.name, entry.size):
                    raise ValueError('batch file ID changed')
                if any(other != i and safe_name(e.name) == safe_name(entry.name) for other, e in metadata.items()):
                    raise ValueError('duplicate batch basename')
                metadata[i] = entry
                contents.setdefault(i, bytearray()); sequences.setdefault(i, 0)
                if entry.size == 0:
                    complete.add(i)
            total = sum(e.size for e in metadata.values())
            if total > batch.size or (len(metadata) == batch.count and total != batch.size):
                raise ValueError('batch metadata total differs from accepted offer')
            control(2, trans, struct.pack('!' + 'H' * len(part), *part))
        elif settings and kind == 4 and trans == transaction and not result.get('file_received'):
            if len(payload) < 6:
                raise ValueError('short batch DATA')
            file_id = struct.unpack_from('!H', payload)[0]
            if file_id not in metadata or file_id in complete:
                raise ValueError('unexpected batch DATA file ID')
            entry, content = metadata[file_id], contents[file_id]
            chunk = framing.decrypt_data_chunk(key, header, payload, sequences[file_id], file_id=file_id)
            if not chunk or len(content) + len(chunk) > entry.size:
                raise ValueError('batch DATA size exceeded')
            end = len(content) + len(chunk) == entry.size
            if flags != (3 if end else (0 if sequences[file_id] == 0 else 1)):
                raise ValueError('batch DATA flag mismatch')
            content.extend(chunk); sequences[file_id] += 1
            if end:
                complete.add(file_id)
            result['received_progress_bytes'] = sum(len(c) for c in contents.values())
        elif result.get('file_received') and kind == 7 and trans == transaction and session == 0 and flags == 0:
            if t.dfile_decrypt_control(key, header, payload) != b'':
                raise ValueError('invalid batch DONE ACK')
            result['dfile_done_ack_verified'] = True
            save()
            return
        else:
            raise ValueError('unsupported batch receive stage')
        if len(complete) == batch.count and not result.get('file_received'):
            publish()
            control(6, transaction, struct.pack('!' + 'H' * batch.count, *sorted(complete)))
            result['dfile_done_sent'] = True
        if kind != 4 or counts.get('4', 0) % 256 == 0 or result.get('file_received'):
            save()
        yield
    raise ValueError('too many batch receive frames')
