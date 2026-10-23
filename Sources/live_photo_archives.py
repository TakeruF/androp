# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 anDrop contributors
"""Bounded extraction of OShare's explicitly marked Live Photo transport ZIPs."""
import asyncio
import os
from pathlib import Path
import re
import stat
import struct
import unicodedata
import zipfile
import zlib


MAX_MEDIA = 512 * 1024 * 1024
MAX_CENTRAL = 64 * 1024
MAX_NAME = 255
CHUNK = 1024 * 1024
_ARCHIVE = re.compile(
    r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
    r'@olive(?: \([1-9][0-9]{0,8}\))?\.zip', re.IGNORECASE)
_IMAGES = {'.jpg', '.jpeg', '.heic', '.heif', '.png'}
_VIDEOS = {'.mov', '.mp4'}
_ERROR = 'live_photo_invalid_archive'


def is_olive_archive(path):
    """Recognize vendor names, including Finder-style numeric collision suffixes."""
    return _ARCHIVE.fullmatch(Path(path).name) is not None


def _extra(data):
    offset = 0
    while offset < len(data):
        if offset + 4 > len(data):
            raise ValueError(_ERROR)
        kind, length = struct.unpack_from('<HH', data, offset)
        offset += 4
        if kind == 1 or offset + length > len(data):  # ZIP64 is deliberately unsupported.
            raise ValueError(_ERROR)
        offset += length


def _name(raw, flags):
    try:
        name = raw.decode('utf-8' if flags & 0x800 else 'cp437')
    except UnicodeError:
        raise ValueError(_ERROR) from None
    if (not raw or len(raw) > MAX_NAME or name in ('.', '..')
            or any(c in name for c in '/\\:')
            or any(unicodedata.category(c) in ('Cc', 'Cf') for c in name)):
        raise ValueError(_ERROR)
    return name


def _directory(source, size):
    """Bound metadata before ZipFile allocates objects from the central directory."""
    if not 22 <= size <= MAX_MEDIA + MAX_CENTRAL + 4096:
        raise ValueError(_ERROR)
    source.seek(max(0, size - 65557))
    tail = source.read(65557)
    end = tail.rfind(b'PK\x05\x06')
    if end < 0 or len(tail) - end < 22:
        raise ValueError(_ERROR)
    signature, disk, central_disk, disk_count, count, length, offset, comment = struct.unpack_from(
        '<4s4H2IH', tail, end)
    end_offset = size - len(tail) + end
    if (disk != 0 or central_disk != 0 or disk_count != count or count not in (2, 3)
            or length > MAX_CENTRAL or offset == 0xffffffff
            or offset + length != end_offset or end + 22 + comment != len(tail)):
        raise ValueError(_ERROR)
    source.seek(0)
    if source.read(4) != b'PK\x03\x04':
        raise ValueError(_ERROR)  # No self-extracting/prefixed archives.
    source.seek(offset)
    directory = source.read(length)
    position = 0
    entries = []
    names = set()
    total = 0
    for _ in range(count):
        if position + 46 > length or directory[position:position + 4] != b'PK\x01\x02':
            raise ValueError(_ERROR)
        fields = struct.unpack_from('<4s6H3I5H2I', directory, position)
        (_, made, needed, flags, method, _, _, crc, compressed, expanded,
         name_size, extra_size, comment_size, start_disk, internal, external, local) = fields
        next_position = position + 46 + name_size + extra_size + comment_size
        if (next_position > length or needed > 20 or flags & ~0x80e
                or method not in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED)
                or start_disk != 0 or local >= offset or compressed > MAX_MEDIA
                or expanded <= 0 or expanded > MAX_MEDIA
                or (method == zipfile.ZIP_STORED and compressed != expanded)):
            raise ValueError(_ERROR)
        mode = external >> 16
        kind = stat.S_IFMT(mode)
        if kind not in (0, stat.S_IFREG) or external & 0x10:
            raise ValueError(_ERROR)
        raw = directory[position + 46:position + 46 + name_size]
        name = _name(raw, flags)
        folded = name.casefold()
        if folded in names:
            raise ValueError(_ERROR)
        names.add(folded)
        _extra(directory[position + 46 + name_size:position + 46 + name_size + extra_size])
        total += expanded
        if total > MAX_MEDIA:
            raise ValueError(_ERROR)
        entries.append((name, local, compressed, expanded, flags, method, crc))
        position = next_position
    if position != length or min(entry[1] for entry in entries) != 0:
        raise ValueError(_ERROR)
    # Check every local header, including ZIP64/encryption flags hidden there.
    spans = []
    for name, local, compressed, expanded, flags, method, crc in entries:
        source.seek(local)
        header = source.read(30)
        if len(header) != 30 or header[:4] != b'PK\x03\x04':
            raise ValueError(_ERROR)
        _, needed, local_flags, local_method, _, _, local_crc, local_size, local_expanded, ns, es = struct.unpack(
            '<4s5H3I2H', header)
        data_end = local + 30 + ns + es + compressed
        if (needed > 20 or local_flags != flags or local_method != method
                or ns > MAX_NAME or es > MAX_CENTRAL or data_end > offset
                or local_size == 0xffffffff or local_expanded == 0xffffffff):
            raise ValueError(_ERROR)
        if not flags & 8 and (local_size != compressed or local_expanded != expanded or local_crc != crc):
            raise ValueError(_ERROR)
        if _name(source.read(ns), flags) != name:
            raise ValueError(_ERROR)
        _extra(source.read(es))
        spans.append((local, data_end, flags, crc, compressed, expanded))
    spans.sort()
    for index, (_, data_end, flags, crc, compressed, expanded) in enumerate(spans):
        next_start = spans[index + 1][0] if index + 1 < len(spans) else offset
        gap = next_start - data_end
        if not flags & 8:
            if gap != 0:
                raise ValueError(_ERROR)
        else:
            if gap not in (12, 16):
                raise ValueError(_ERROR)
            source.seek(data_end)
            descriptor = source.read(gap)
            if gap == 16:
                if descriptor[:4] != b'PK\x07\x08':
                    raise ValueError(_ERROR)
                descriptor = descriptor[4:]
            if struct.unpack('<3I', descriptor) != (crc, compressed, expanded):
                raise ValueError(_ERROR)
    return entries


def _members(entries):
    images = []
    videos = []
    gains = []
    for entry in entries:
        path = Path(entry[0])
        if path.suffix.lower() in _IMAGES:
            (gains if path.stem.casefold().endswith('_gainmap') else images).append(entry)
        elif path.suffix.lower() in _VIDEOS:
            videos.append(entry)
        else:
            raise ValueError(_ERROR)
    if len(images) != 1 or len(videos) != 1 or len(gains) > 1:
        raise ValueError(_ERROR)
    image, video = images[0], videos[0]
    stem = Path(image[0]).stem.casefold()
    if Path(video[0]).stem.casefold() != stem:
        raise ValueError(_ERROR)
    if gains and gains[0][0].casefold() != stem + '_gainmap.jpg':
        raise ValueError(_ERROR)
    return [(image, 'still' + Path(image[0]).suffix.lower()),
            (video, 'motion' + Path(video[0]).suffix.lower())] + (
                [(gains[0], 'gainmap.jpg')] if gains else [])


async def extract_olive_archive(source, workspace):
    """Extract validated components to fixed names; the caller owns workspace cleanup."""
    source = Path(source)
    workspace = Path(workspace)
    if not is_olive_archive(source) or workspace.is_symlink() or not workspace.is_dir():
        raise ValueError(_ERROR)
    fd = None
    try:
        fd = os.open(source, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode):
            raise ValueError(_ERROR)
        with os.fdopen(fd, 'rb') as incoming:
            fd = None
            members = _members(_directory(incoming, before.st_size))
            with zipfile.ZipFile(incoming, 'r') as archive:
                for entry, target in members:
                    info = archive.getinfo(entry[0])
                    # ZipFile must agree with the bounded directory interpretation.
                    if (info.header_offset, info.compress_size, info.file_size,
                            info.flag_bits, info.compress_type, info.CRC) != entry[1:]:
                        raise ValueError(_ERROR)
                    written = 0
                    with archive.open(info, 'r') as component, (workspace / target).open('xb') as output:
                        while True:
                            block = component.read(min(CHUNK, entry[3] - written + 1))
                            if not block:
                                break
                            written += len(block)
                            if written > entry[3]:
                                raise ValueError(_ERROR)
                            output.write(block)
                            await asyncio.sleep(0)
                    if written != entry[3]:
                        raise ValueError(_ERROR)
            after = os.fstat(incoming.fileno())
            if (before.st_size, before.st_mtime_ns, before.st_ctime_ns) != (
                    after.st_size, after.st_mtime_ns, after.st_ctime_ns):
                raise ValueError(_ERROR)
        return workspace / members[0][1], workspace / members[1][1]
    except (OSError, ValueError, RuntimeError, NotImplementedError, EOFError,
            zipfile.BadZipFile, zlib.error):
        # No untrusted filename or ZIP exception text reaches diagnostics/UI.
        raise ValueError(_ERROR) from None
    finally:
        if fd is not None:
            os.close(fd)
