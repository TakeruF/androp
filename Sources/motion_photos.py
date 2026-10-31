# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 anDrop contributors
"""Local Live Photo conversion; originals and the network protocol stay intact.

JPEG Motion Photos follow Android's public XMP container specification. Huawei
moving pictures use a separate, fixed 60-byte trailer. AVFoundation handles
Apple metadata and remuxing in the bundled native helper, without Photos access.
"""
import asyncio
from dataclasses import dataclass
import json
import os
from pathlib import Path
import plistlib
import re
import struct
import sys
from sandbox_files import bookmarks_for
import tempfile
import xml.etree.ElementTree as ET
from live_photo_archives import is_olive_archive, extract_olive_archive

MAX_MEDIA = 512 * 1024 * 1024
MAX_HEADER = 1024 * 1024
XMP = b'http://ns.adobe.com/xap/1.0/\0'
CAMERA = 'http://ns.google.com/photos/1.0/camera/'
CONTAINER = 'http://ns.google.com/photos/1.0/container/'
ITEM = 'http://ns.google.com/photos/1.0/container/item/'
STILLS = {'.jpg', '.jpeg', '.heic', '.heif'}
VIDEOS = {'.mov', '.mp4'}


class MotionPhotoError(ValueError):
    pass


@dataclass(frozen=True)
class MotionPhoto:
    image_length: int
    video_offset: int
    video_length: int
    timestamp_us: int = -1
    format: str = 'android'
    cover_frame: int = -1


def _video(source, offset, length):
    """Check complete ISO BMFF framing, not a substring masquerading as MP4."""
    if length < 24 or offset < 4:
        return False
    end = offset + length
    types = set()
    source.seek(offset)
    for _ in range(10000):
        position = source.tell()
        if position == end:
            return {b'ftyp', b'moov', b'mdat'} <= types
        header = source.read(8)
        if len(header) != 8:
            return False
        size, kind = struct.unpack('!I4s', header)
        header_length = 8
        if size == 1:
            extended = source.read(8)
            if len(extended) != 8:
                return False
            size = struct.unpack('!Q', extended)[0]
            header_length = 16
        elif size == 0:
            size = end - position
        if size < header_length or position + size > end or (position == offset and kind != b'ftyp'):
            return False
        types.add(kind)
        source.seek(position + size)
    return False


def _jpeg_xmp(source):
    source.seek(0)
    if source.read(2) != b'\xff\xd8':
        return []
    packets = []
    while source.tell() < MAX_HEADER:
        if source.read(1) != b'\xff':
            return []
        marker = source.read(1)
        while marker == b'\xff':
            marker = source.read(1)
        if marker in (b'\xda', b'\xd9', b''):
            break
        length = source.read(2)
        if len(length) != 2:
            return []
        size = struct.unpack('!H', length)[0]
        if size < 2 or source.tell() + size - 2 > MAX_HEADER:
            return []
        body = source.read(size - 2)
        if len(body) != size - 2:
            return []
        if marker == b'\xe1' and body.startswith(XMP):
            packets.append(body[len(XMP):])
    return packets


def _property(root, namespace, name):
    key = '{' + namespace + '}' + name
    for element in root.iter():
        if key in element.attrib:
            return element.attrib[key]
        if element.tag == key:
            return element.text
    return None


def motion_photo(path):
    """Return bounded, validated byte ranges; a damaged marker is an ordinary file."""
    path = Path(path)
    if path.suffix.lower() not in STILLS or path.is_symlink() or not path.is_file():
        return None
    size = path.stat().st_size
    if not 64 <= size <= MAX_MEDIA:
        return None
    with path.open('rb') as source:
        source.seek(-60, os.SEEK_END)
        footer = source.read(60)
        version = re.fullmatch(rb'[vV][0-9]{1,3}_[fF]([0-9]{1,7})[ \0]*', footer[:20])
        if version is not None and footer[40:45] == b'LIVE_':
            try:
                value = footer[45:60].strip(b' \0')
                if not value.isdigit():
                    return None
                length = int(value) - 20
                offset = size - 60 - length
                start_ms, cover_ms = (int(v) for v in footer[20:40].strip(b' \0').split(b':'))
                cover = int(version[1])
                if 0 <= start_ms <= cover_ms <= 86400000 and cover <= 1000000 and _video(source, offset, length):
                    return MotionPhoto(offset, offset, length, cover_ms * 1000, 'huawei', cover)
            except (ValueError, OSError):
                return None
        for packet in _jpeg_xmp(source):
            if b'<!DOCTYPE' in packet.upper() or b'<!ENTITY' in packet.upper():
                continue
            try:
                root = ET.fromstring(packet)
                enabled = _property(root, CAMERA, 'MotionPhoto')
                if enabled is not None and enabled != '1':
                    continue
                timestamp = int(_property(root, CAMERA, 'MotionPhotoPresentationTimestampUs') or '-1')
                if not -1 <= timestamp <= 24 * 3600 * 1000000:
                    continue
                entries = list(root.iter('{' + CONTAINER + '}Item'))
                if entries:
                    last = entries[-1]
                    if (_property(last, ITEM, 'Semantic') != 'MotionPhoto'
                            or _property(last, ITEM, 'Mime') not in ('video/mp4', 'video/quicktime')):
                        continue
                    length = int(_property(last, ITEM, 'Length') or '0')
                else:
                    # Legacy Google/Samsung Motion Photos have a backwards offset.
                    if _property(root, CAMERA, 'MicroVideo') != '1':
                        continue
                    length = int(_property(root, CAMERA, 'MicroVideoOffset') or '0')
                    timestamp = int(_property(root, CAMERA, 'MicroVideoPresentationTimestampUs') or '-1')
                offset = size - length
                if _video(source, offset, length):
                    return MotionPhoto(offset, offset, length, timestamp)
            except (ET.ParseError, ValueError, OverflowError, OSError):
                continue
        # The public HEIC Motion Photo format wraps the movie in a final mpvd box.
        if path.suffix.lower() in ('.heic', '.heif'):
            source.seek(0)
            for index in range(10000):
                position = source.tell()
                header = source.read(8)
                if len(header) != 8:
                    break
                length, kind = struct.unpack('!I4s', header)
                if index == 0 and kind != b'ftyp':
                    break
                if length < 8 or position + length > size:
                    break
                if kind == b'mpvd' and position + length == size and _video(source, position + 8, length - 8):
                    return MotionPhoto(position, position + 8, length - 8)
                source.seek(position + length)
    return None


async def _copy_range(source, target, offset, length):
    with Path(source).open('rb') as incoming, Path(target).open('xb') as outgoing:
        incoming.seek(offset)
        while length:
            block = incoming.read(min(length, 1024 * 1024))
            if not block:
                raise MotionPhotoError('motion_photo_source_changed')
            outgoing.write(block)
            length -= len(block)
            await asyncio.sleep(0)


def helper_path():
    if getattr(sys, 'frozen', False):
        # Engine lives at Contents/Resources/Engine/anDropEngine.
        return Path(sys.executable).resolve().parents[2] / 'MacOS/anDropLivePhoto'
    return Path(__file__).resolve().parents[1] / 'build/anDropLivePhoto'


async def native(command, image, video, output=None, timestamp=-1):
    args = [str(helper_path()), command, str(image), str(video)]
    if output is not None:
        args += [str(output), str(timestamp)]
    bookmarks = bookmarks_for([image, video] + ([Path(output).parent] if output is not None else []))
    if bookmarks: args.append('--sandbox-bookmarks')
    process = await asyncio.create_subprocess_exec(*args, stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL)
    try:
        stdout, _ = await asyncio.wait_for(process.communicate(json.dumps(bookmarks).encode()), 90)
        if process.returncode or len(stdout) > 8192:
            raise MotionPhotoError('motion_photo_conversion_failed')
        result = json.loads(stdout)
        if not isinstance(result, dict):
            raise MotionPhotoError('motion_photo_conversion_failed')
        return result
    finally:
        if process.returncode is None:
            process.kill()
            await process.wait()


def _xmp(video_length, timestamp, packets=(), *, motion=True):
    """Replace motion declarations in one XMP packet, preserving other metadata."""
    from io import BytesIO
    from xml.sax.saxutils import quoteattr

    rdf = 'http://www.w3.org/1999/02/22-rdf-syntax-ns#'
    oplus = 'http://ns.oplus.com/photos/1.0/camera/'
    namespaces = {'x': 'adobe:ns:meta/', 'rdf': rdf, 'Camera': CAMERA,
                  'Container': CONTAINER, 'Item': ITEM, 'OpCamera': oplus}
    root = ET.Element('{adobe:ns:meta/}xmpmeta')
    graph = ET.SubElement(root, '{' + rdf + '}RDF')
    for packet in packets:
        if b'<!DOCTYPE' in packet.upper() or b'<!ENTITY' in packet.upper():
            raise MotionPhotoError('motion_photo_invalid_xmp')
        try:
            for _, (prefix, uri) in ET.iterparse(BytesIO(packet), events=('start-ns',)):
                # Conflicting scoped prefixes can occur in arbitrary XML. Do not
                # silently change QName-valued private metadata while flattening.
                if prefix in namespaces and namespaces[prefix] != uri:
                    raise MotionPhotoError('motion_photo_ambiguous_xmp_namespace')
                namespaces[prefix] = uri
            parsed = ET.fromstring(packet)
        except ET.ParseError as error:
            raise MotionPhotoError('motion_photo_invalid_xmp') from error
        graphs = [parsed] if parsed.tag == '{' + rdf + '}RDF' else list(parsed.iter('{' + rdf + '}RDF'))
        if len(graphs) != 1:
            raise MotionPhotoError('motion_photo_invalid_xmp')
        graph.extend(list(graphs[0]))
    if not packets and not motion:
        return b''

    camera_fields = {'MotionPhoto', 'MotionPhotoVersion', 'MotionPhotoPresentationTimestampUs',
                     'MicroVideo', 'MicroVideoVersion', 'MicroVideoOffset',
                     'MicroVideoPresentationTimestampUs', 'MediaDataOffset'}
    oplus_fields = {'MotionPhotoOwner', 'OLivePhotoVersion', 'MotionPhotoFeatureFlag',
                    'VideoLength', 'MotionPhotoPrimaryPresentationTimestampUs'}
    obsolete = {'{' + namespace + '}' + name
                for namespace, names in ((CAMERA, camera_fields), (oplus, oplus_fields)) for name in names}
    for parent in root.iter():
        for name in obsolete:
            parent.attrib.pop(name, None)
        for child in list(parent):
            if child.tag in obsolete:
                parent.remove(child)

    directories = list(root.iter('{' + CONTAINER + '}Directory'))
    # Multiple independent directories cannot be merged without guessing how
    # their gainmap byte ranges overlap. Preserve the source by refusing export.
    if len(directories) > 1:
        raise MotionPhotoError('motion_photo_ambiguous_xmp_container')
    sequence = None
    if directories:
        sequence = directories[0].find('{' + rdf + '}Seq')
        if sequence is None:
            raise MotionPhotoError('motion_photo_invalid_xmp_container')
        for entry in list(sequence):
            item = entry.find('{' + CONTAINER + '}Item')
            if item is not None and _property(item, ITEM, 'Semantic') == 'MotionPhoto':
                sequence.remove(entry)
    if motion:
        description = ET.SubElement(graph, '{' + rdf + '}Description', {'{' + rdf + '}about': ''})
        fields = {'MotionPhoto': 1, 'MotionPhotoVersion': 1, 'MotionPhotoPresentationTimestampUs': timestamp,
                  'MicroVideo': 1, 'MicroVideoVersion': 1, 'MicroVideoOffset': video_length,
                  'MicroVideoPresentationTimestampUs': timestamp}
        description.attrib.update({'{' + CAMERA + '}' + key: str(value) for key, value in fields.items()})
        fields = {'MotionPhotoOwner': 'oplus', 'OLivePhotoVersion': 2, 'MotionPhotoFeatureFlag': 1,
                  'VideoLength': video_length, 'MotionPhotoPrimaryPresentationTimestampUs': timestamp}
        description.attrib.update({'{' + oplus + '}' + key: str(value) for key, value in fields.items()})
        if sequence is None:
            directory = ET.SubElement(description, '{' + CONTAINER + '}Directory')
            sequence = ET.SubElement(directory, '{' + rdf + '}Seq')
        primary = [item for item in sequence.iter('{' + CONTAINER + '}Item')
                   if _property(item, ITEM, 'Semantic') == 'Primary']
        if len(primary) > 1:
            raise MotionPhotoError('motion_photo_invalid_xmp_container')
        if not primary:
            entry = ET.Element('{' + rdf + '}li', {'{' + rdf + '}parseType': 'Resource'})
            ET.SubElement(entry, '{' + CONTAINER + '}Item', {
                '{' + ITEM + '}Mime': 'image/jpeg', '{' + ITEM + '}Semantic': 'Primary',
                '{' + ITEM + '}Length': '0', '{' + ITEM + '}Padding': '0'})
            sequence.insert(0, entry)
        entry = ET.SubElement(sequence, '{' + rdf + '}li', {'{' + rdf + '}parseType': 'Resource'})
        ET.SubElement(entry, '{' + CONTAINER + '}Item', {
            '{' + ITEM + '}Mime': 'video/mp4', '{' + ITEM + '}Semantic': 'MotionPhoto',
            '{' + ITEM + '}Length': str(video_length), '{' + ITEM + '}Padding': '0'})

    for prefix, uri in namespaces.items():
        if not re.fullmatch(r'ns[0-9]+', prefix):
            ET.register_namespace(prefix, uri)
    xml = ET.tostring(root, encoding='utf-8')
    # ElementTree omits declarations referenced only by private QName values.
    # Retain those too, so unknown metadata keeps its namespace context.
    missing = []
    for prefix, uri in namespaces.items():
        declaration = ('xmlns' + (':' + prefix if prefix else '') + '=').encode()
        if declaration not in xml:
            missing.append(b' ' + declaration + quoteattr(uri).encode())
    if missing:
        end = xml.index(b'>')
        xml = xml[:end] + b''.join(missing) + xml[end:]
    body = XMP + xml
    if len(body) > 65533:
        raise MotionPhotoError('motion_photo_xmp_too_large')
    return b'\xff\xe1' + struct.pack('!H', len(body) + 2) + body


def _jpeg_metadata(path):
    """Read JPEG header segments only; the compressed tail is copied verbatim."""
    segments, packets = [], []
    with Path(path).open('rb') as stream:
        if stream.read(2) != b'\xff\xd8':
            raise MotionPhotoError('motion_photo_expected_jpeg')
        while stream.tell() < MAX_HEADER:
            start = stream.tell()
            if stream.read(1) != b'\xff':
                raise MotionPhotoError('motion_photo_invalid_jpeg')
            marker = stream.read(1)
            while marker == b'\xff':
                marker = stream.read(1)
            if marker in (b'\xda', b'\xd9'):
                return segments, packets, start
            if marker == b'\x01' or (marker and b'\xd0' <= marker <= b'\xd7'):
                end = stream.tell()
            else:
                length = stream.read(2)
                if len(length) != 2:
                    raise MotionPhotoError('motion_photo_invalid_jpeg')
                size = struct.unpack('!H', length)[0]
                if size < 2 or stream.tell() + size - 2 > MAX_HEADER:
                    raise MotionPhotoError('motion_photo_invalid_jpeg')
                body = stream.read(size - 2)
                if len(body) != size - 2:
                    raise MotionPhotoError('motion_photo_invalid_jpeg')
                end = stream.tell()
                if marker == b'\xe1' and body.startswith(XMP):
                    packets.append(body[len(XMP):])
                    continue
                if marker == b'\xe1' and body.startswith(b'http://ns.adobe.com/xmp/extension/\0'):
                    raise MotionPhotoError('motion_photo_extended_xmp_unsupported')
            stream.seek(start)
            segments.append(stream.read(end - start))
        raise MotionPhotoError('motion_photo_jpeg_header_too_large')


def _mpf(image_size):
    """One baseline primary image; all TIFF offsets are relative to its header."""
    entries = (struct.pack('!HHI4s', 0xb000, 7, 4, b'0100')
               + struct.pack('!HHII', 0xb001, 4, 1, 1)
               + struct.pack('!HHII', 0xb002, 7, 16, 50))
    body = (b'MPF\0MM\0*\0\0\0\x08' + struct.pack('!H', 3) + entries + b'\0' * 4
            + struct.pack('!IIIHH', 0x00030000, image_size, 0, 0, 0))
    return b'\xff\xe2' + struct.pack('!H', len(body) + 2) + body


def _single_primary_mpf(segment):
    """Recognize a replaceable one-image MP index; never guess gainmap offsets."""
    segment = b'\xff' + segment.lstrip(b'\xff')  # Legal JPEG marker fill bytes.
    data = segment[8:]  # JPEG marker/length and MPF signature precede TIFF.
    if len(data) < 8 or data[:2] not in (b'MM', b'II'):
        return False
    order = '!' if data[:2] == b'MM' else '<'
    try:
        if struct.unpack_from(order + 'H', data, 2)[0] != 42:
            return False
        offset = struct.unpack_from(order + 'I', data, 4)[0]
        count = struct.unpack_from(order + 'H', data, offset)[0]
        if not 3 <= count <= 64 or offset + 2 + count * 12 + 4 > len(data):
            return False
        entries = {}
        for index in range(count):
            location = offset + 2 + index * 12
            tag, kind, length = struct.unpack_from(order + 'HHI', data, location)
            if tag in entries:
                return False
            entries[tag] = kind, length, data[location + 8:location + 12]
        version, number, table = (entries.get(tag) for tag in (0xb000, 0xb001, 0xb002))
        if (version != (7, 4, b'0100') or number is None or table is None
                or number[:2] != (4, 1) or table[:2] != (7, 16)
                or struct.unpack(order + 'I', number[2])[0] != 1):
            return False
        table_offset = struct.unpack(order + 'I', table[2])[0]
        attribute, image_size, image_offset, dependent_a, dependent_b = struct.unpack_from(order + 'IIIHH', data, table_offset)
        return (attribute in (0x00030000, 0x20030000) and 0 < image_size <= MAX_MEDIA
                and image_offset == dependent_a == dependent_b == 0
                and struct.unpack_from(order + 'I', data, offset + 2 + count * 12)[0] == 0)
    except (struct.error, ValueError, TypeError):
        return False


async def compose(image, video, target, *, format='android', timestamp=-1, cover_frame=0, frame_count=1):
    """Write a new JPEG container, retaining compressed image and movie bytes."""
    image, video, target = Path(image), Path(video), Path(target)
    image_size, video_size = image.stat().st_size, video.stat().st_size
    if image_size + video_size > MAX_MEDIA:
        raise MotionPhotoError('motion_photo_too_large')
    if format not in ('android', 'huawei') or not -1 <= timestamp <= 24 * 3600 * 1000000:
        raise MotionPhotoError('motion_photo_invalid_metadata')
    segments, packets, tail_offset = _jpeg_metadata(image)
    metadata = _xmp(video_size, timestamp, packets, motion=format == 'android')
    if metadata:
        graph = ET.fromstring(metadata[4 + len(XMP):])
        if any(_property(item, ITEM, 'Semantic') not in ('Primary', 'MotionPhoto')
               for item in graph.iter('{' + CONTAINER + '}Item')):
            raise MotionPhotoError('motion_photo_auxiliary_images_unsupported')
    existing_mpf = [segment for segment in segments
                    if segment.lstrip(b'\xff').startswith(b'\xe2')
                    and segment.lstrip(b'\xff')[3:7] == b'MPF\0']
    if len(existing_mpf) > 1 or any(not _single_primary_mpf(segment) for segment in existing_mpf):
        raise MotionPhotoError('motion_photo_mpf_unsupported')
    # Replacing EXIF/XMP changes the primary image size. Rebuild verified single
    # image MPF tables, and refuse multi-image/gainmap layouts before writing.
    segments = [segment for segment in segments if segment not in existing_mpf]
    rewritten_size = 2 + len(metadata) + sum(map(len, segments)) + image_size - tail_offset
    mpf = _mpf(rewritten_size + len(_mpf(0))) if format == 'android' else b''
    with target.open('xb') as stream:
        stream.write(b'\xff\xd8')
        stream.write(metadata)
        stream.write(mpf)
        for segment in segments:
            stream.write(segment)
        for source, offset, remaining in ((image, tail_offset, image_size - tail_offset), (video, 0, video_size)):
            with source.open('rb') as handle:
                handle.seek(offset)
                while remaining:
                    block = handle.read(min(remaining, 1024 * 1024))
                    if not block:
                        raise MotionPhotoError('motion_photo_source_changed')
                    stream.write(block)
                    remaining -= len(block)
                    await asyncio.sleep(0)
        if format == 'huawei':
            cover_ms = max(0, timestamp // 1000)
            fields = [f'v3_f{cover_frame}', f'{max(0, cover_ms - 600)}:{cover_ms}', f'LIVE_{video_size + 20}']
            if not (0 <= cover_frame < frame_count <= 1000000) or any(len(x) > 20 for x in fields):
                raise MotionPhotoError('motion_photo_invalid_metadata')
            stream.write(b''.join(x.encode('ascii').ljust(20, b' ') for x in fields))
    return target


def _bundle_pair(path):
    if path.suffix.lower() != '.pvt' or path.is_symlink() or not path.is_dir():
        return None
    children = list(path.iterdir())
    if len(children) > 16 or any(p.is_symlink() or not p.is_file() for p in children):
        raise MotionPhotoError('live_photo_invalid_bundle')
    images = [p for p in children if p.suffix.lower() in STILLS]
    videos = [p for p in children if p.suffix.lower() in VIDEOS]
    if len(images) != 1 or len(videos) != 1:
        raise MotionPhotoError('live_photo_invalid_bundle')
    return images[0], videos[0]


def _quarantine(path):
    # Darwin's xattr API has position/options arguments and is not exposed by
    # Python's os module on macOS. Use the same API as the existing receiver.
    import ctypes
    libc = ctypes.CDLL(None, use_errno=True)
    getter = libc.getxattr
    getter.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]
    getter.restype = ctypes.c_ssize_t
    buffer = ctypes.create_string_buffer(65536)
    length = getter(os.fsencode(path), b'com.apple.quarantine', buffer, len(buffer), 0, 0)
    return bytes(buffer[:length]) if length > 0 else None


def _set_quarantine(path, value):
    import ctypes
    libc = ctypes.CDLL(None, use_errno=True)
    setter = libc.setxattr
    setter.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]
    if setter(os.fsencode(path), b'com.apple.quarantine', value, len(value), 0, 0) != 0:
        raise OSError(ctypes.get_errno(), 'could not mark derived photo')


async def prepare_send(paths, workspace, target='android'):
    """Collapse metadata-matched Apple pairs; never drop an unrelated movie."""
    paths = [Path(p) for p in paths]
    workspace = Path(workspace)
    replacements, consumed = {}, set()
    for index, path in enumerate(paths):
        if path in consumed or path.suffix.lower() not in STILLS | {'.pvt'}:
            continue
        embedded = motion_photo(path)
        pair = _bundle_pair(path)
        if embedded is not None:
            if (embedded.format == 'huawei') == (target == 'huawei'):
                continue
            workspace.mkdir(parents=True, exist_ok=True, mode=0o700)
            components = workspace / ('source-' + str(index))
            components.mkdir(mode=0o700)
            image = components / ('still' + path.suffix.lower())
            video = components / 'motion.mp4'
            await _copy_range(path, image, 0, embedded.image_length)
            await _copy_range(path, video, embedded.video_offset, embedded.video_length)
            pair = image, video
        elif pair is None and path.suffix.lower() in STILLS:
            # Explicit same-basename sidecars only; never search a Photos library.
            candidates = [p for p in paths if p.stem.casefold() == path.stem.casefold() and p.suffix.lower() in VIDEOS]
            if not candidates:
                candidates = [path.with_suffix(ext) for ext in ('.mov', '.MOV', '.mp4', '.MP4') if path.with_suffix(ext).is_file()]
            if len(candidates) == 1:
                pair = path, candidates[0]
        if pair is None:
            continue
        image, video = pair
        invalid = image.is_symlink() or video.is_symlink() or image.stat().st_size + video.stat().st_size > MAX_MEDIA
        if invalid:
            if path.suffix.lower() == '.pvt' or embedded is not None:
                raise MotionPhotoError('live_photo_invalid_pair')
            continue
        if embedded is None:
            try:
                info = await native('inspect', image, video)
            except (OSError, ValueError):
                info = {}
            if not info.get('is_live_photo'):
                if path.suffix.lower() == '.pvt':
                    raise MotionPhotoError('live_photo_invalid_pair')
                continue
        workspace.mkdir(parents=True, exist_ok=True, mode=0o700)
        output = workspace / ('converted-' + str(index))
        timestamp = -1
        if embedded is not None:
            timestamp = 'frame:' + str(embedded.cover_frame) if embedded.format == 'huawei' else embedded.timestamp_us
        exported = await native('android', image, video, output, timestamp)
        converted = workspace / (path.stem + ('.jpg' if target == 'huawei' else '.MP.jpg'))
        await compose(exported['image'], exported['video'], converted, format=target,
                      timestamp=exported.get('timestamp_us', -1), cover_frame=exported.get('cover_frame', 0),
                      frame_count=exported.get('frame_count', 1))
        replacements[path] = converted
        if embedded is None:
            consumed.add(video)
    return [replacements.get(path, path) for path in paths if path not in consumed]


async def materialize_received(saved, diagnostic=None):
    """Save Live Photo packages; consume OLive transport ZIPs after conversion."""
    result = list(saved)
    for item in saved:
        source = Path(item['path'])
        try:
            archive = is_olive_archive(source)
            archive_stat = source.stat(follow_symlinks=False) if archive else None
            info = None if archive else motion_photo(source)
            if info is None and not archive:
                continue
            with tempfile.TemporaryDirectory(prefix='.anDrop-LivePhoto-', dir=source.parent) as folder:
                folder = Path(folder)
                if archive:
                    components = folder / 'components'
                    components.mkdir(mode=0o700)
                    still, video = await extract_olive_archive(source, components)
                    # This vendor ZIP carries no manifest with a cover time.
                    # The helper uses embedded still-time metadata when present,
                    # otherwise the midpoint; it validates the generated pair.
                    timestamp = -1
                else:
                    still = folder / ('still' + source.suffix.lower())
                    video = folder / 'motion.mp4'
                    await _copy_range(source, still, 0, info.image_length)
                    await _copy_range(source, video, info.video_offset, info.video_length)
                    timestamp = info.timestamp_us
                    if info.format == 'huawei' and info.cover_frame >= 0:
                        timestamp = 'frame:' + str(info.cover_frame)
                output = folder / 'photo.pvt'
                await native('apple', still, video, output, timestamp)
                (output / 'metadata.plist').write_bytes(plistlib.dumps({'PFVideoComplementMetadataVersionKey': '1'}))
                # Every derived resource keeps the same quarantine as its source.
                quarantine = _quarantine(source)
                if quarantine:
                    for child in [output, *output.iterdir()]:
                        _set_quarantine(child, quarantine)
                from huawei_runtime import place_exclusive
                for attempt in range(10000):
                    name = source.stem + (f' ({attempt})' if attempt else '') + '.pvt'
                    package = source.parent / name
                    try:
                        place_exclusive(output, package)
                        break
                    except FileExistsError:
                        continue
                else:
                    raise MotionPhotoError('live_photo_name_collision')
                result.append({'path': str(package), 'bytes': sum(p.stat().st_size for p in package.iterdir()),
                               'kind': 'live_photo'})
                if diagnostic:
                    diagnostic('live_photo_converted')
                if archive:
                    try:
                        current = source.stat(follow_symlinks=False)
                        identity = lambda s: (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns)
                        if identity(current) != identity(archive_stat):
                            raise OSError('live_photo_archive_changed')
                        source.unlink()
                    except OSError:
                        if diagnostic:
                            diagnostic('live_photo_cleanup_failed')
                    else:
                        # Deleted transport files must not survive in the
                        # completion event or persisted Finder history.
                        result = [record for record in result if record.get('path') != item['path']]
        except asyncio.CancelledError:
            raise
        except (OSError, ValueError, KeyError, asyncio.TimeoutError):
            # Failed conversion keeps the received original and transfer success.
            if diagnostic:
                diagnostic('live_photo_conversion_failed')
    return result
