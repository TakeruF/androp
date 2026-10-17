#!/usr/bin/env python3
"""Offline investigation of one Huawei Share receiver binary, not a sender.

Requires the user's locally acquired libshare_service_plugin.z.so and Unicorn.
Executes bounded AArch64 dispatch/copy snippets from the real binary. This is
not full service emulation: C++ string operations are stubbed, and no network,
authentication, file transfer, or phone UI is exercised. No vendor code/assets
are included in this repository or copied into the application.
"""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import struct

SUPPORTED_SHA256 = '681c401dfe48931b8e57c0865a9f2f71a49797541c016412c3206e1d48437468'


def investigate(binary):
    from unicorn import Uc, UC_ARCH_ARM64, UC_MODE_ARM, UC_HOOK_CODE
    from unicorn.arm64_const import (
        UC_ARM64_REG_X0, UC_ARM64_REG_X1, UC_ARM64_REG_X2,
        UC_ARM64_REG_X19, UC_ARM64_REG_X20, UC_ARM64_REG_X21,
        UC_ARM64_REG_X29, UC_ARM64_REG_X30, UC_ARM64_REG_SP,
        UC_ARM64_REG_PC,
    )
    digest = hashlib.sha256(binary).hexdigest()
    if digest != SUPPORTED_SHA256:
        raise ValueError('unsupported binary: addresses are specific to the recorded device build')
    if binary[:6] != b'\x7fELF\x02\x01' or struct.unpack_from('<H', binary, 18)[0] != 183:
        raise ValueError('expected little-endian AArch64 ELF')
    uc = Uc(UC_ARCH_ARM64, UC_MODE_ARM)
    uc.mem_map(0, 0x200000)
    phoff = struct.unpack_from('<Q', binary, 32)[0]
    stride, count = struct.unpack_from('<HH', binary, 54)
    for index in range(count):
        kind, _, offset, address, _, size, _, _ = struct.unpack_from(
            '<IIQQQQQQ', binary, phoff + index * stride)
        if kind == 1:
            uc.mem_write(address, binary[offset:offset + size])
    uc.mem_map(0x400000, 0x10000)  # Synthetic objects; never phone memory.
    uc.mem_map(0x600000, 0x10000)  # Stack.
    uc.mem_map(0x800000, 0x10000)  # Synthetic strings.
    allocation = 0x800000

    def put_string(address, data):
        nonlocal allocation
        pointer = allocation
        allocation += (len(data) + 16) & ~7
        uc.mem_write(pointer, data + b'\0')
        uc.mem_write(address, struct.pack('<QQQ', (len(data) + 1) | 1, len(data), pointer))

    def get_string(address):
        raw = bytes(uc.mem_read(address, 24))
        if raw[0] & 1:
            _, size, pointer = struct.unpack('<QQQ', raw)
            if size > 4096:
                raise ValueError('unexpected synthetic string length')
            return bytes(uc.mem_read(pointer, size))
        return raw[1:1 + (raw[0] >> 1)]

    def run(start, stops, registers=None, string_stubs=False):
        uc.reg_write(UC_ARM64_REG_SP, 0x608000)
        uc.reg_write(UC_ARM64_REG_X29, 0x608100)
        for register, value in (registers or {}).items():
            uc.reg_write(register, value)
        reached = []

        def step(machine, address, size, _):
            if address in stops:
                reached.append(address)
                machine.emu_stop()
            elif string_stubs and address in (0x1997c0, 0x67d68, 0x1996c0):
                destination = machine.reg_read(UC_ARM64_REG_X0)
                source = machine.reg_read(UC_ARM64_REG_X1)
                if address == 0x1997c0:  # string(char*, length)
                    length = machine.reg_read(UC_ARM64_REG_X2)
                    if length > 4096:
                        raise ValueError('unexpected string constructor length')
                    data = bytes(machine.mem_read(source, length))
                else:  # string assignment; copy is sufficient for these snippets.
                    data = get_string(source)
                put_string(destination, data)
                machine.reg_write(UC_ARM64_REG_PC, machine.reg_read(UC_ARM64_REG_X30))

        hook = uc.hook_add(UC_HOOK_CODE, step)
        try:
            uc.emu_start(start, 0x1ffffc, count=100)
        finally:
            uc.hook_del(hook)
        if len(reached) != 1:
            raise ValueError('snippet did not reach a recognized boundary')
        return reached[0]

    initial_targets = {
        0x16c1bc: 'integer', 0x16b6d8: 'string',
        0x16c274: 'int64', 0x16c294: 'unsupported',
    }
    initial = {}
    later = {}
    for tag in range(256):
        initial[tag] = initial_targets[run(0x16c160, initial_targets, {UC_ARM64_REG_X1: tag})]
        destination = run(0x16b66c, (0x16b684, 0x16b688), {UC_ARM64_REG_X21: tag})
        later[tag] = 'string' if destination == 0x16b684 else 'ignored'
    if [tag for tag, kind in initial.items() if kind == 'string'] != [2, 7, 10, 11, 13]:
        raise ValueError('unexpected initial string dispatch')
    if [tag for tag, kind in later.items() if kind == 'string'] != [11, 13]:
        raise ValueError('unexpected subsequent preview dispatch')

    # Execute the actual non-BytesInfo category branch. This explains why
    # changing the offer from 1 to 3 changes the notification route even if
    # the filename, bytes and thumbnail fields are otherwise identical.
    # Stop before construction/callbacks: this does not render either UI.
    category_receiver = 0x405000
    category_targets = {0x16d9d4: 'file', 0x16dc70: 'SendBean'}
    categories = {}
    for send_type in (1, 3, 4, 8):
        uc.mem_write(category_receiver + 1384, struct.pack('<I', send_type))
        categories[str(send_type)] = category_targets[run(
            0x16d9c0, category_targets, {UC_ARM64_REG_X19: category_receiver})]
    if categories != {'1': 'SendBean', '3': 'file', '4': 'file', '8': 'file'}:
        raise ValueError('unexpected Apple preview category route')

    # The ordinary RecvSessionV1 route (distinct from AppleRecvSession):
    # field 68 -> receiver +1504 -> RecvPreview +64 (previewData).
    tag_address, receiver, vector, preview = 0x400000, 0x401000, 0x402000, 0x403000
    string_destinations = {
        0xd1be8: 1424, 0xd1ce4: 1472, 0xd1cfc: 1504,
        0xd1d14: 1552, 0xd1d2c: 1608, 0xd1d44: 1528,
        0xd1d5c: 1632, 0xd1d74: 'delegate', 0xd1c3c: 'helper',
        0xd1db0: 736,
    }
    standard_strings = {}
    for tag in range(65, 81):
        uc.mem_write(tag_address, struct.pack('<I', tag))
        address = run(0xd1bc0, string_destinations, {UC_ARM64_REG_X21: tag_address})
        standard_strings[str(tag)] = string_destinations[address]
    if {tag: standard_strings[str(tag)] for tag in (65, 68, 71, 73, 75, 76, 78, 80)} != {
            65: 1472, 68: 1504, 71: 1424, 73: 1608,
            75: 1424, 76: 1528, 78: 1632, 80: 736}:
        raise ValueError('unexpected standard preview field mapping')
    preview_states = {}
    for state in (1, 2, 10, 12, 14):
        uc.mem_write(receiver + 1280, struct.pack('<I', state))
        boundary = run(0xd3538, (0xd3540, 0xd3aa8), {UC_ARM64_REG_X20: receiver})
        preview_states[str(state)] = 'parse' if boundary == 0xd3540 else 'defer'
    if preview_states != {'1': 'defer', '2': 'defer', '10': 'parse', '12': 'parse', '14': 'defer'}:
        raise ValueError('unexpected standard preview state gate')
    uc.mem_write(tag_address, struct.pack('<I', 68))
    target = run(0xd1bc0, (0xd1cfc, 0xd1c3c), {UC_ARM64_REG_X21: tag_address})
    if target != 0xd1cfc:
        raise ValueError('standard preview image field not recognized')
    # A self-contained 1x1 PNG is sufficient to trace bytes. It is not a PDF
    # icon and does not claim that the real UI rendered the preview.
    thumbnail = 'data:image/png;base64,' + base64.b64encode(bytes.fromhex(
        '89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c489'
        '0000000b49444154789c6360000200000500017a5eab3f0000000049454e44ae426082'
    )).decode('ascii')
    payload = json.dumps([{'thumbnail': thumbnail}], separators=(',', ':')).encode()
    data_address = 0x404000
    uc.mem_write(data_address, payload)
    uc.mem_write(vector, struct.pack('<QQQ', data_address, data_address + len(payload), data_address + len(payload)))
    run(0xd1cfc, (0xd1c04,), {
        UC_ARM64_REG_X19: receiver, UC_ARM64_REG_X20: vector,
    }, string_stubs=True)
    if get_string(receiver + 1504) != payload:
        raise ValueError('preview bytes did not reach receiver storage')
    run(0xd12c4, (0xd12d8,), {
        UC_ARM64_REG_X19: receiver, UC_ARM64_REG_X20: preview,
    }, string_stubs=True)
    if get_string(preview + 64) != payload:
        raise ValueError('preview bytes did not reach UI handoff structure')

    return {
        'binary_sha256': digest,
        'scope': 'bounded native dispatch snippets; standard-library string stubs; no live UI',
        'apple_initial_accepted_fields': {str(k): v for k, v in initial.items() if v != 'unsupported'},
        'apple_later_accepted_fields': [k for k, v in later.items() if v != 'ignored'],
        'apple_tag12_initial': initial[12],
        'apple_tag12_later': later[12],
        'apple_tag68_initial': initial[68],
        'dispatch_cases_executed': 513,
        'apple_non_bytes_category_routes': categories,
        'category_cases_executed': len(categories),
        'standard_string_dispatch_storage_offsets': standard_strings,
        'standard_preview_state_gate': preview_states,
        'standard_route': {
            'receiver': 'RecvSessionV1', 'field': 68,
            'receiver_storage_offset': 1504, 'recv_preview_offset': 64,
            'synthetic_payload_bytes': len(payload),
            'payload_preserved_to_preview_data': True,
        },
        'live_transport_verified': False,
        'live_icon_verified': False,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    result = investigate(args.binary.read_bytes())
    rendered = json.dumps(result, indent=2) + '\n'
    if args.output:
        args.output.write_text(rendered)
    print(rendered, end='')


if __name__ == '__main__':
    main()
