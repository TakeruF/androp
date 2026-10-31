# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 anDrop contributors

"""Content classification for the OShare offer, independent of the ZIP transport."""
import mimetypes
from pathlib import Path

# Even a private MimeTypes() first initializes the global database, reading
# /etc/apache2/mime.types on macOS. Only use Python's built-in wire mappings;
# system files are both unnecessary and unavailable inside App Sandbox.
_knownfiles = mimetypes.knownfiles
try:
    mimetypes.knownfiles = []
    _TYPES = mimetypes.MimeTypes()
finally:
    mimetypes.knownfiles = _knownfiles
_EXTRA = {
    '.heic': 'image/heic', '.heif': 'image/heif', '.avif': 'image/avif',
    '.webp': 'image/webp', '.mkv': 'video/x-matroska',
    '.7z': 'application/x-7z-compressed', '.rar': 'application/x-rar-compressed',
}
_ENCODINGS = {
    'gzip': 'application/gzip', 'bzip2': 'application/x-bzip2',
    'xz': 'application/x-xz', 'compress': 'application/x-compress',
    'br': 'application/x-brotli',
}


def file_mime_type(path):
    suffix = Path(path).suffix.lower()
    # Use only the extension: filename characters such as ? and # are not URLs.
    mime, encoding = _TYPES.guess_type('file' + suffix, strict=False)
    if encoding:
        return _ENCODINGS.get(encoding, 'file/*')
    return _EXTRA.get(suffix) or (mime if mime and mime != 'application/octet-stream' else 'file/*')


def offer_mime_type(files):
    types = {file_mime_type(path) for path in files}
    if len(types) == 1:
        return next(iter(types))
    families = {mime.split('/', 1)[0] for mime in types}
    if len(families) == 1 and families <= {'image', 'audio', 'video'}:
        return next(iter(families)) + '/*'
    return 'file/*'
