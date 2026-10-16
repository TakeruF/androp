#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 anDrop contributors
"""Fail a build if a bundled executable requires a newer macOS than advertised."""
from pathlib import Path
import argparse
import re
import subprocess

MAGIC = {b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'}

def version(value):
    return tuple((list(map(int, value.split('.'))) + [0, 0])[:3])

def check(app, minimum, arch):
    errors = []
    count = 0
    for path in app.rglob('*'):
        if not path.is_file() or path.is_symlink():
            continue
        with path.open('rb') as source:
            if source.read(4) not in MAGIC:
                continue
        count += 1
        relative = path.relative_to(app)
        architectures = subprocess.check_output(['lipo', '-archs', str(path)], text=True).split()
        if arch not in architectures:
            errors.append(f'{relative}: missing {arch}')
            continue
        commands = subprocess.check_output(['otool', '-arch', arch, '-l', str(path)], text=True)
        matches = re.findall(r'cmd LC_BUILD_VERSION\s+cmdsize \d+\s+platform \d+\s+minos ([0-9.]+)', commands)
        matches += re.findall(r'cmd LC_VERSION_MIN_MACOSX\s+cmdsize \d+\s+version ([0-9.]+)', commands)
        if not matches:
            errors.append(f'{relative}: missing deployment target')
        elif any(version(value) > version(minimum) for value in matches):
            errors.append(f'{relative}: requires macOS {max(matches, key=version)}, declared {minimum}')
        libraries = subprocess.check_output(['otool', '-arch', arch, '-L', str(path)], text=True)
        for dependency in libraries.splitlines()[1:]:
            name = dependency.strip().split(' (compatibility version')[0]
            if name.startswith(('/Users/', '/opt/homebrew/', '/usr/local/', '/private/tmp/')):
                errors.append(f'{relative}: external build-machine dependency')
    if not count:
        errors.append('No Mach-O binaries found')
    if errors:
        raise SystemExit('Runtime compatibility check failed:\n' + '\n'.join(errors))
    print(f'Checked {count} Mach-O files: {arch}, macOS {minimum} or earlier, no build-machine library paths.')

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('--minimum', required=True)
    parser.add_argument('--arch', required=True)
    args = parser.parse_args()
    check(args.app, args.minimum, args.arch)
