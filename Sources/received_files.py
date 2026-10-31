# SPDX-License-Identifier: GPL-3.0-only
"""Quarantine completed downloads without replacing macOS-owned metadata."""
import ctypes
import os
import time


def quarantine_value(path):
    libc = ctypes.CDLL(None, use_errno=True)
    getter = libc.getxattr
    getter.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p,
                       ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]
    getter.restype = ctypes.c_ssize_t
    value = ctypes.create_string_buffer(256)
    size = getter(os.fsencode(path), b'com.apple.quarantine', value, len(value), 0, 1)
    if size < 0:
        raise OSError(ctypes.get_errno(), 'could not read download quarantine')
    return value.raw[:size]


def mark_download(path):
    # App Sandbox quarantines created files itself. Replacing that attribute
    # may be denied, and must never downgrade flags set by the operating system.
    try:
        value = quarantine_value(path)
        if int(value.split(b';', 1)[0], 16) & 3:
            return
    except (OSError, ValueError):
        pass
    libc = ctypes.CDLL(None, use_errno=True)
    setter = libc.setxattr
    setter.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p,
                       ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]
    value = f'0083;{int(time.time()):x};anDrop;'.encode()
    if setter(os.fsencode(path), b'com.apple.quarantine', value, len(value), 0, 1) != 0:
        raise OSError(ctypes.get_errno(), 'could not mark received file')
