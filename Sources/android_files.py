# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 anDrop contributors
"""Bounded Android ZIP preparation and incremental receipt on disk workers."""
import asyncio
from collections import Counter
import hashlib
import os
from pathlib import Path, PurePosixPath
import queue
import stat
import tempfile
import threading
import zipfile
import zlib

from received_files import mark_download
from stream_unzip import NO_ENCRYPTION, NotStreamUnzippable, stream_unzip

COPY_CHUNK = 1024 * 1024


def safe_name(raw):
    name = raw.replace('\\', '/'); path = PurePosixPath(name)
    if not name or path.is_absolute() or any(x in ('', '..', '.') for x in name.split('/')) or '\x00' in name:
        raise ValueError('Unsafe archive path')
    name = path.name
    if any(ord(c) < 32 or c in ':/' for c in name) or len(name.encode()) > 240:
        raise ValueError('Unsupported file name')
    return name


def validate_archive(archive, expected_count, expected_size):
    entries = [x for x in archive.infolist() if not x.is_dir()]
    if not 1 <= expected_count <= 10000 or len(entries) != expected_count:
        raise ValueError('File count mismatch')
    if sum(x.file_size for x in entries) != expected_size:
        raise ValueError('File size mismatch')
    for entry in archive.infolist():
        safe_name(entry.filename.rstrip('/'))
        mode = entry.external_attr >> 16
        if (stat.S_ISLNK(mode) or stat.S_IFMT(mode) not in (0, stat.S_IFREG, stat.S_IFDIR)
                or entry.flag_bits & 1):
            raise ValueError('Unsupported archive entry')
    return entries


def _identity(info):
    return info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns


async def create_archive(files, archive_path):
    """Build the ZIP on a disk worker, opening one source file at a time."""
    stopped = threading.Event()
    def work():
        total = 0
        with zipfile.ZipFile(archive_path, 'w', zipfile.ZIP_STORED, allowZip64=True) as archive:
            for path in files:
                if stopped.is_set(): return
                info = path.stat()
                fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
                try:
                    if not stat.S_ISREG(info.st_mode) or _identity(os.fstat(fd)) != _identity(info):
                        raise ValueError('Source changed before archive preparation')
                    source = os.fdopen(fd, 'rb')
                except BaseException:
                    os.close(fd)
                    raise
                with source, archive.open(path.name, 'w', force_zip64=True) as output:
                    copied = 0
                    while chunk := source.read(COPY_CHUNK):
                        if stopped.is_set(): return
                        output.write(chunk); copied += len(chunk)
                        if copied > info.st_size: raise ValueError('Source changed during archive preparation')
                    if copied != info.st_size or _identity(os.fstat(source.fileno())) != _identity(info):
                        raise ValueError('Source changed during archive preparation')
                    total += copied
        return total
    worker = asyncio.create_task(asyncio.to_thread(work))
    try:
        return await asyncio.shield(worker)
    except BaseException:
        stopped.set()
        await asyncio.gather(worker, return_exceptions=True)
        raise


def _publish(temporary, name, size, digest, destination, saved):
    with open(temporary, 'rb') as source:
        if hashlib.file_digest(source, 'sha256').hexdigest() != digest:
            raise ValueError('Saved file readback mismatch')
    mark_download(temporary)
    for attempt in range(10000):
        final = destination / (name if not attempt else f'{Path(name).stem} ({attempt}){Path(name).suffix}')
        try:
            os.link(temporary, final)
            break
        except FileExistsError:
            continue
    else:
        raise ValueError('Too many files with the same name')
    saved.append({'path': str(final), 'bytes': size, 'sha256': digest})


async def receive_archive(chunks, archive_path, destination, count, total, progress, saved):
    """Publish CRC/size/readback-verified files while the ZIP is still arriving.

    A two-chunk queue applies backpressure. ZIP parsing, hashing and disk writes
    stay off the event loop. Already published files survive failure/cancellation.
    Central-directory metadata is checked before reporting overall success.
    """
    if not 1 <= count <= 10000 or total < 0: raise ValueError('Invalid transfer metadata')
    destination = Path(destination).resolve(strict=True)
    if not destination.is_dir(): raise ValueError('Save folder is unavailable')
    incoming = queue.Queue(maxsize=2)
    stopped = threading.Event(); end = object(); state = {'written': 0}
    limit = total + max(COPY_CHUNK, count * 65536)
    iterator = chunks.__aiter__()
    def check_cancelled():
        if stopped.is_set(): raise InterruptedError('Archive receipt cancelled')
    def work():
        streamed = []; fallback = False
        with Path(archive_path).open('wb') as spool:
            def source():
                while True:
                    check_cancelled()
                    try: chunk = incoming.get(timeout=.1)
                    except queue.Empty: continue
                    if chunk is end: return
                    spool.write(chunk)
                    yield chunk
            source_chunks = source()
            try:
                for raw_name, size, contents in stream_unzip(source_chunks, allowed_encryption_mechanisms=(NO_ENCRYPTION,)):
                    check_cancelled()
                    try: decoded = raw_name.decode('utf-8')
                    except UnicodeDecodeError: decoded = raw_name.decode('cp437')
                    directory = decoded.endswith('/')
                    name = safe_name(decoded.rstrip('/') if directory else decoded)
                    if directory:
                        for chunk in contents:
                            check_cancelled()
                            if chunk: raise ValueError('Unsupported directory payload')
                        continue
                    if len(streamed) >= count: raise ValueError('File count mismatch')
                    if size is not None and (size < 0 or size > total - state['written']):
                        raise ValueError('File size mismatch')
                    fd, temporary = tempfile.mkstemp(prefix='.anDrop-', dir=destination)
                    try:
                        digest, length, crc = hashlib.sha256(), 0, 0
                        with os.fdopen(fd, 'wb') as output:
                            for chunk in contents:
                                check_cancelled()
                                length += len(chunk); state['written'] += len(chunk)
                                if state['written'] > total or (size is not None and length > size):
                                    raise ValueError('Unexpected file size')
                                output.write(chunk); digest.update(chunk); crc = zlib.crc32(chunk, crc)
                            output.flush(); os.fsync(output.fileno())
                        # Exhaustion of contents verifies the ZIP CRC/data descriptor.
                        if size is not None and length != size: raise ValueError('Incomplete file')
                        check_cancelled()
                        _publish(temporary, name, length, digest.hexdigest(), destination, saved)
                        streamed.append((raw_name, length, crc))
                    finally:
                        os.unlink(temporary)
            except NotStreamUnzippable:
                # Some STORED ZIPs omit local sizes. Preserve compatibility by
                # finishing the disk spool, then extracting their remaining files.
                fallback = True
                for _ in source_chunks: check_cancelled()
        check_cancelled()
        with zipfile.ZipFile(archive_path) as archive:
            entries = validate_archive(archive, count, total)
            # Check each central-directory entry against its local header and
            # ZIP overlap bounds without decompressing a second time.
            for entry in archive.infolist():
                with archive.open(entry):
                    pass
            def metadata(entry):
                return (entry.filename.encode('utf-8' if entry.flag_bits & 0x800 else 'cp437'), entry.file_size, entry.CRC)
            remaining = Counter(metadata(entry) for entry in entries)
            for record in streamed:
                remaining[record] -= 1
                if remaining[record] < 0: raise ValueError('ZIP local/central metadata mismatch')
            if fallback:
                state['written'] = sum(item['bytes'] for item in saved)
                for entry in entries:
                    record = metadata(entry)
                    if remaining[record] <= 0: continue
                    check_cancelled()
                    fd, temporary = tempfile.mkstemp(prefix='.anDrop-', dir=destination)
                    try:
                        digest, length = hashlib.sha256(), 0
                        with os.fdopen(fd, 'wb') as output, archive.open(entry) as source:
                            while chunk := source.read(COPY_CHUNK):
                                check_cancelled()
                                length += len(chunk); state['written'] += len(chunk)
                                if length > entry.file_size or state['written'] > total: raise ValueError('Unexpected file size')
                                output.write(chunk); digest.update(chunk)
                            output.flush(); os.fsync(output.fileno())
                        if length != entry.file_size: raise ValueError('Incomplete file')
                        check_cancelled()
                        _publish(temporary, safe_name(entry.filename), length, digest.hexdigest(), destination, saved)
                        remaining[record] -= 1
                    finally:
                        os.unlink(temporary)
            if any(remaining.values()) or len(saved) != count or sum(item['bytes'] for item in saved) != total:
                raise ValueError('ZIP file count or size mismatch')
        return saved
    worker = asyncio.create_task(asyncio.to_thread(work))
    pending_read = None
    async def put(chunk):
        while True:
            if worker.done():
                await worker
                raise ValueError('ZIP decoder stopped before download completed')
            try:
                incoming.put_nowait(chunk)
                return
            except queue.Full:
                await asyncio.sleep(.001)
    async def read_next(): return await anext(iterator)
    try:
        downloaded = 0
        while True:
            pending_read = asyncio.create_task(read_next())
            done, _ = await asyncio.wait((pending_read, worker), return_when=asyncio.FIRST_COMPLETED)
            if worker in done:
                await worker
                raise ValueError('ZIP decoder stopped before download completed')
            try: chunk = pending_read.result()
            except StopAsyncIteration: break
            if not chunk: continue
            downloaded += len(chunk)
            if downloaded > limit: raise ValueError('Transfer exceeds declared size')
            await put(chunk)
            progress(state['written'], total)
        await put(end)
        result = await asyncio.shield(worker)
        progress(total, total)
        return result
    except BaseException:
        stopped.set()
        raise
    finally:
        if pending_read is not None:
            if not pending_read.done(): pending_read.cancel()
            await asyncio.gather(pending_read, return_exceptions=True)
        if not worker.done(): stopped.set()
        await asyncio.gather(worker, return_exceptions=True)
