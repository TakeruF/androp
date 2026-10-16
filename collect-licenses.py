# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 anDrop contributors

from pathlib import Path
import urllib.request
import sysconfig
import shutil
import subprocess
import importlib.metadata as m
root=Path(__file__).parent/'ThirdPartyNotices';root.mkdir(exist_ok=True)
names=['aiohttp','aiohappyeyeballs','aiosignal','attrs','frozenlist','multidict','propcache','yarl','idna','bleak','pyobjc-core','pyobjc-framework-Cocoa','pyobjc-framework-CoreBluetooth','pyobjc-framework-libdispatch','cryptography','cffi','pycparser','altgraph','packaging','macholib','pyinstaller-hooks-contrib','pyinstaller','setuptools']
lines=['Dependency inventory from the anDrop build environment.','PyInstaller is used under its bootloader exception.','Protocol-reference licenses: mtapy-LICENSE (GPL-3.0), CatShare-LICENSE (MIT).','These two references are not bundled runtime dependencies. See NOTICE.md.','']
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
brew=shutil.which('brew')
for name,formula,filename in [('OpenSSL','openssl@3','LICENSE.txt'),('liblzma','xz','COPYING.0BSD'),('zstd','zstd','LICENSE')]:
 if not brew:
  missing.append(name);continue
 result=subprocess.run([brew,'--prefix',formula],text=True,capture_output=True)
 src=Path(result.stdout.strip())/filename
 if result.returncode==0 and src.is_file():(root/(name+'-LICENSE.txt')).write_bytes(src.read_bytes())
 else:missing.append(name)
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
