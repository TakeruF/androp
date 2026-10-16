# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 anDrop contributors

from pathlib import Path
import urllib.request
import sysconfig
import shutil
import subprocess
import importlib.metadata as m
import ssl
import sys
import argparse
parser=argparse.ArgumentParser()
parser.add_argument("--python-notices",type=Path,help="Python installer documentation license.rst.txt")
args=parser.parse_args()
root=Path(__file__).parent/'ThirdPartyNotices';root.mkdir(exist_ok=True)
names=['aiohttp','aiohappyeyeballs','aiosignal','attrs','frozenlist','multidict','propcache','yarl','idna','bleak','pyobjc-core','pyobjc-framework-Cocoa','pyobjc-framework-CoreBluetooth','pyobjc-framework-libdispatch','cryptography','cffi','pycparser','altgraph','packaging','macholib','pyinstaller-hooks-contrib','pyinstaller','setuptools']
lines=['Dependency inventory from the anDrop build environment.','PyInstaller is used under its bootloader exception.','Protocol-reference licenses: mtapy-LICENSE (GPL-3.0), CatShare-LICENSE (MIT).','These two references are not bundled runtime dependencies. See NOTICE.md.','Sparkle 2.10.0: MIT and bundled third-party notices; see Sparkle-LICENSE.txt.','']
for name in names:
 try:d=m.distribution(name)
 except m.PackageNotFoundError:raise SystemExit(f'Missing build dependency: {name}')
 lines.append(f'{name} {d.version}: {d.metadata.get("License-Expression") or d.metadata.get("License") or "See component license"}')
 for f in d.files or []:
  if ('.dist-info/' in str(f) or '.egg-info/' in str(f)) and any(w in f.name.lower() for w in ['license','copying','notice']):
   src=Path(d.locate_file(f))
   if src.is_file():(root/(name+'-'+f.name)).write_bytes(src.read_bytes())
missing=[]
python_license=Path(sysconfig.get_path('stdlib'))/'LICENSE.txt'
if python_license.is_file():(root/'Python-LICENSE.txt').write_bytes(python_license.read_bytes())
else:missing.append('Python runtime')
# Collect versioned native notices from their upstream projects, not from an
# unrelated Homebrew runtime. The official Python installer statically embeds
# liblzma and other libraries; its complete incorporated-software notices are
# required for release collection.
if args.python_notices:
 (root/'Python-incorporated-software-LICENSE.txt').write_bytes(args.python_notices.read_bytes())
 lines.append('Python incorporated-software notices: from the matching official Python installer documentation.')
else:
 lines.append('Review Python-incorporated-software-LICENSE.txt against the exact Python distribution before release.')
openssl_version=ssl.OPENSSL_VERSION.split()[1]
import ctypes
zstd=Path(sys.base_prefix)/'lib/libzstd.1.dylib'
if zstd.is_file():
 library=ctypes.CDLL(str(zstd));library.ZSTD_versionString.restype=ctypes.c_char_p
 zstd_version=library.ZSTD_versionString().decode()
else:
 raise SystemExit('Provide the exact runtime Zstandard library for license collection.')
for name,url in [
 ('OpenSSL',f'https://raw.githubusercontent.com/openssl/openssl/openssl-{openssl_version}/LICENSE.txt'),
 ('zstd',f'https://raw.githubusercontent.com/facebook/zstd/v{zstd_version}/LICENSE'),
 ('liblzma','https://raw.githubusercontent.com/tukaani-project/xz/v5.2.3/COPYING'),
]:
 content=urllib.request.urlopen(url,timeout=30).read()
 if len(content)<100:raise ValueError('Unexpected native license content')
 (root/(name+'-LICENSE.txt')).write_bytes(content)
 lines.append(f'{name} notice source: {url}')
lines.append('Python runtime: '+sys.version.split()[0]+'; OpenSSL '+openssl_version+'; Zstandard '+zstd_version+'.')
# These wheels omit their license file. Keep the upstream versioned copies.
for name in ['pyobjc-core','pyobjc-framework-libdispatch']:
 target=root/(name+'-LICENSE.txt')
 version=m.version(name)
 url=f'https://raw.githubusercontent.com/ronaldoussoren/pyobjc/v{version}/{name}/License.txt'
 content=urllib.request.urlopen(url,timeout=20).read()
 if b'Permission is hereby granted' not in content:raise ValueError('Unexpected upstream license')
 target.write_bytes(content)
 lines.append(f'{name} license source: {url}')
lines.append('PyObjC links to macOS system libffi; no separate libffi library is bundled.')
(root/'README.txt').write_text('\n'.join(lines)+'\n')
if missing:raise SystemExit('Review runtime licenses not collected: '+', '.join(missing))
print('Dependency license inventory updated.')
