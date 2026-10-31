#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Verify actual App Sandbox denial/grants using only isolated dummy data.

Run using a macOS-14-compatible Python environment with requirements.txt.
Uses ANDROP_SIGN_IDENTITY when set; no installed application is changed.
"""
import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import uuid
import zipfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'Sources'))
from sandbox_files import bookmarks_for


def run(*args, **kwargs):
    try:
        return subprocess.run([str(a) for a in args], check=True, timeout=180, **kwargs)
    except subprocess.CalledProcessError as error:
        if error.stderr: sys.stderr.buffer.write(error.stderr[:12000])
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', required=True, type=Path)
    options = parser.parse_args()
    identity = os.environ.get('ANDROP_SIGN_IDENTITY', '-')
    parent = ROOT / 'build/sandbox-checks'
    parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='fixtures-', dir=parent) as temporary:
        root = Path(temporary).resolve()
        app = root / 'SandboxChecks.app'
        resources = app / 'Contents/Resources'
        executable = app / 'Contents/MacOS/SandboxChecks'
        executable.parent.mkdir(parents=True); resources.mkdir()
        bundle_id = 'org.androp.tests.sandbox.' + uuid.uuid4().hex
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': bundle_id, 'CFBundleExecutable': 'SandboxChecks',
            'CFBundlePackageType': 'APPL', 'LSUIElement': True,
        }))
        # The exact built converter is exercised as a second inherited child.
        shutil.copy2(options.app / 'Contents/MacOS/anDropLivePhoto', executable.parent / 'anDropLivePhoto')
        run('swiftc', '-swift-version', '6', '-parse-as-library', '-target', 'arm64-apple-macos14.0',
            ROOT / 'Sources/FileAccess.swift', ROOT / 'scripts/SandboxChecks.swift', '-o', executable)
        run(sys.executable, '-m', 'PyInstaller', '--noconfirm', '--clean', '--onedir',
            '--name', 'SandboxProbe', '--paths', ROOT / 'Sources', '--distpath', resources,
            '--workpath', root / 'work', '--specpath', root, ROOT / 'scripts/SandboxProbe.py',
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        rights = run('codesign', '-d', '--entitlements', ':-', options.app, capture_output=True).stdout
        host_rights = plistlib.loads(rights)
        host_rights.pop('com.apple.security.temporary-exception.mach-lookup.global-name', None)
        host_entitlements = root / 'host.plist'; host_entitlements.write_bytes(plistlib.dumps(host_rights))
        inherit = root / 'inherit.plist'; inherit.write_bytes(plistlib.dumps({
            'com.apple.security.app-sandbox': True, 'com.apple.security.inherit': True,
        }))
        probe = resources / 'SandboxProbe/SandboxProbe'
        # Re-sign all probe libraries to the same team before signing its host.
        magic = {b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'}
        for path in (resources / 'SandboxProbe').rglob('*'):
            if not path.is_file() or path.is_symlink(): continue
            with path.open('rb') as binary: header = binary.read(4)
            if header in magic:
                args = ['codesign', '--force', '--sign', identity, '--options', 'runtime']
                if path == probe: args += ['--entitlements', inherit]
                run(*args, path, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        run('codesign', '--force', '--sign', identity, '--options', 'runtime', '--entitlements', host_entitlements, app,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        run('codesign', '--verify', '--deep', '--strict', app)
        fixture = root / 'LivePhotoFixture'
        run('swiftc', '-swift-version', '6', '-suppress-warnings', '-parse-as-library', ROOT / 'Sources/Localization.swift',
            ROOT / 'Sources/LivePhotoImporter.swift', ROOT / 'scripts/LivePhotoFixture.swift', '-o', fixture)
        media = root / 'media'; media.mkdir()
        run(fixture, 'generate', media, stdout=subprocess.DEVNULL)
        selected = root / 'selected.txt'; selected.write_text('sandbox fixture')
        denied = root / 'denied.txt'; denied.write_text('must not be readable')
        archive = root / 'incoming.zip'
        with zipfile.ZipFile(archive, 'w') as z: z.writestr('received.txt', b'received fixture')
        destination = root / 'destination'; destination.mkdir()
        paths = [selected, archive, media / 'source.jpg', media / 'source.mov']
        request = {'paths': [str(p) for p in paths], 'bookmarks': bookmarks_for(paths),
                   'destination': str(destination), 'destination_bookmark': bookmarks_for([destination])[0],
                   'denied': str(denied)}
        first = run(executable, input=json.dumps(request).encode(), capture_output=True)
        checks = json.loads(first.stdout)
        second = run(executable, input=json.dumps({'restore': True, 'destination': str(destination), 'denied': str(denied)}).encode(), capture_output=True)
        checks.update(json.loads(second.stdout))
        assert all(checks.values()), checks
        print(json.dumps({'checks': checks, 'passed': len(checks)}, indent=2))
        # macOS owns this uniquely named test container; leave it untouched.


if __name__ == '__main__': main()
