#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 anDrop contributors
"""Fetch the pinned official Sparkle release after verifying its SHA-256."""
from pathlib import Path
import hashlib
import json
import shutil
import tarfile
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]

def fetch_sparkle():
    config = json.loads((ROOT / 'release.json').read_text())['sparkle']
    cache = ROOT / 'build/dependencies'
    cache.mkdir(parents=True, exist_ok=True)
    archive = cache / ('Sparkle-' + config['version'] + '.tar.xz')
    if not archive.exists():
        with urllib.request.urlopen(config['url'], timeout=120) as response:
            with archive.open('wb') as output:
                shutil.copyfileobj(response, output)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != config['sha256']:
        raise SystemExit('Sparkle archive checksum mismatch. Remove the cached archive and retry.')
    destination = cache / ('Sparkle-' + config['version'])
    with tempfile.TemporaryDirectory(prefix='sparkle-', dir=cache) as temporary:
        with tarfile.open(archive) as source:
            members = [m for m in source.getmembers() if m.name.removeprefix('./').split('/')[0] in ('Sparkle.framework', 'bin', 'LICENSE')]
            source.extractall(temporary, members=members, filter='data')
        if not (Path(temporary) / 'Sparkle.framework/Sparkle').is_file():
            raise SystemExit('The verified archive does not contain the expected Sparkle framework.')
        if destination.exists():
            shutil.rmtree(destination)
        shutil.copytree(temporary, destination, symlinks=True)
    return destination

if __name__ == '__main__':
    print(fetch_sparkle())
