#!/usr/bin/env python3
"""Enumerate one recorded AppleRecvSession constructor offline using Unicorn.

Map insertion and C++ function-wrapper construction are stubbed. Executes only
the registration block, not authentication, network, UI, or the whole service.
Requires the locally acquired binary; no vendor code is distributed here.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct

SUPPORTED_SHA256 = '681c401dfe48931b8e57c0865a9f2f71a49797541c016412c3206e1d48437468'


def investigate(binary):
    from unicorn import Uc, UC_ARCH_ARM64, UC_MODE_ARM, UC_HOOK_CODE
    from unicorn import arm64_const as reg

    if hashlib.sha256(binary).hexdigest() != SUPPORTED_SHA256:
        raise ValueError('unsupported binary: constructor addresses are build-specific')
    machine = Uc(UC_ARCH_ARM64, UC_MODE_ARM)
    machine.mem_map(0, 0x200000)
    offset = struct.unpack_from('<Q', binary, 32)[0]
    stride, count = struct.unpack_from('<HH', binary, 54)
    for index in range(count):
        kind, _, start, address, _, size, _, _ = struct.unpack_from(
            '<IIQQQQQQ', binary, offset + index * stride)
        if kind == 1:
            machine.mem_write(address, binary[start:start + size])
    machine.mem_map(0x400000, 0x20000)
    machine.mem_map(0x600000, 0x10000)
    allocation, stack = 0x400000, 0x608000
    seeds = {20: allocation, 21: allocation + 32, 22: 11, 23: 5,
             25: allocation + 1696, 26: allocation + 1392,
             27: stack + 48, 29: stack + 512}
    for number, value in seeds.items():
        machine.reg_write(getattr(reg, f'UC_ARM64_REG_X{number}'), value)
    machine.reg_write(reg.UC_ARM64_REG_SP, stack)
    machine.mem_write(stack + 40, struct.pack('<Q', allocation + 1768))
    machine.mem_write(stack + 512 + 24, struct.pack('<Q', allocation + 1792))
    insertions, wrappers = [], []
    completed = False

    def x(number):
        return machine.reg_read(getattr(reg, f'UC_ARM64_REG_X{number}'))

    def integer(address, width=8):
        return int.from_bytes(machine.mem_read(address, width), 'little')

    def hook(uc, address, size, _):
        nonlocal completed
        if address == 0x102a34:
            completed = True
            uc.emu_stop()
        elif address in (0x6a40c, 0xc6684):
            slot = 0x410000 + len(insertions) * 16
            insertions.append({'map_offset': x(0) - allocation - 32,
                               'id': integer(x(1), 4), 'slot': slot,
                               'insertion_call': hex(x(30) - 4)})
            uc.reg_write(reg.UC_ARM64_REG_X0, slot)
            uc.reg_write(reg.UC_ARM64_REG_PC, x(30))
        elif address in (0xa671c, 0x15bf5c):
            if x(2) > 16:
                raise ValueError('unexpected wrapper count')
            for i in range(x(2)):
                entry = x(1) + i * 64
                vtable = integer(entry + 16)
                if integer(entry + 24) != allocation + 32:
                    raise ValueError('wrapper bound to unexpected receiver')
                wrappers.append({'map_offset': x(0) - allocation - 32,
                                 'id': integer(entry, 4), 'vtable': hex(vtable),
                                 'handler': hex(integer(vtable + 48))})
            uc.reg_write(reg.UC_ARM64_REG_PC, x(30))
        elif address == 0x67000:  # Destroy temporary std::function wrapper.
            uc.reg_write(reg.UC_ARM64_REG_PC, x(30))

    machine.hook_add(UC_HOOK_CODE, hook)
    machine.emu_start(0x102238, 0x102a38, count=3000)
    if not completed:
        raise ValueError('constructor registration block did not finish')
    for entry in insertions:
        slot = entry.pop('slot')
        entry['handler'] = hex(integer(slot))
        if integer(slot + 8) != 0:
            raise ValueError('unexpected member pointer adjustment')
    return {'binary_sha256': SUPPORTED_SHA256, 'offline_only': True,
            'constructor_range': ['0x102238', '0x102a34'],
            'member_handlers': insertions, 'command_wrappers': wrappers}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    result = investigate(args.binary.read_bytes())
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({'member_handlers': len(result['member_handlers']),
                      'command_wrappers': len(result['command_wrappers']),
                      'offline_only': True}))
