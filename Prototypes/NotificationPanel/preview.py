#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 anDrop contributors
"""Build and open a standalone notification UI preview with fictional data."""
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
APP = ROOT / 'build/NotificationPreview.app'
contents = APP / 'Contents'
for folder in ('MacOS', 'Resources'):
    (contents / folder).mkdir(parents=True, exist_ok=True)
(contents / 'Info.plist').write_bytes(plistlib.dumps({
    'CFBundleExecutable': 'NotificationPreview',
    'CFBundleName': 'anDrop Notification Preview',
    'CFBundleIdentifier': 'org.androp.prototype.notification-panel',
    'CFBundlePackageType': 'APPL',
    'CFBundleIconFile': 'AppIcon',
    'NSHighResolutionCapable': True,
    'LSMinimumSystemVersion': '14.0',
}))
shutil.copyfile(ROOT / 'AppIcon.icns', contents / 'Resources/AppIcon.icns')
(contents / 'Resources/BrandLogos').mkdir(exist_ok=True)
shutil.copyfile(ROOT / 'Resources/BrandLogos/oppo.svg', contents / 'Resources/BrandLogos/oppo.svg')
subprocess.run([
    'swiftc', '-swift-version', '6', '-default-isolation', 'MainActor',
    '-parse-as-library', '-module-cache-path', str(ROOT / 'build/notification-module-cache'),
    str(HERE / 'NotificationPreview.swift'),
    '-o', str(contents / 'MacOS/NotificationPreview'),
], check=True)
if '--build-only' not in sys.argv:
    subprocess.run(['open', str(APP), '--args', *sys.argv[1:]], check=True)
print(APP)
