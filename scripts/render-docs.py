#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 anDrop contributors
"""Render documentation images from production SwiftUI views with mock data only."""
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / 'docs/images'
OUTPUT.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='androp-docs-') as temp:
    stage = Path(temp)
    app = stage / 'Documentation.app/Contents'
    (app / 'MacOS').mkdir(parents=True)
    (app / 'Resources').mkdir()
    (app / 'Info.plist').write_bytes(plistlib.dumps({
        'CFBundleExecutable': 'Documentation',
        'CFBundleIdentifier': 'org.androp.documentation-preview',
        'CFBundlePackageType': 'APPL',
    }))
    shutil.copytree(ROOT / 'Resources/BrandLogos', app / 'Resources/BrandLogos')
    shutil.copyfile(ROOT / 'AppIcon.icns', app / 'Resources/AppIcon.icns')
    source = (ROOT / 'Sources/main.swift').read_text()
    source = source.split('let app = NSApplication.shared')[0]
    # The settings view normally reads the system Computer Name. Replace it only
    # in this disposable documentation build; never read it into an image.
    original = 'var deviceName: String { Host.current().localizedName ?? ProcessInfo.processInfo.hostName }'
    assert original in source, 'Review the mock Computer Name override after a source change.'
    source = source.replace(original, 'var deviceName: String { "Studio Mac" }')
    source += (ROOT / 'scripts/DocumentationPreview.swift').read_text()
    generated = stage / 'main.swift'
    generated.write_text(source)
    executable = app / 'MacOS/Documentation'
    subprocess.run([
        'swiftc', '-swift-version', '6', '-default-isolation', 'MainActor',
        '-module-cache-path', str(stage / 'module-cache'),
        *[str(ROOT / 'Sources' / name) for name in
          ['Localization.swift', 'Peer.swift', 'TransferProgress.swift', 'BrandLogos.swift']],
        str(generated), '-o', str(executable),
    ], check=True)
    # This renders views to PNGs without starting the app delegate, Bluetooth,
    # transfer engine, notifications, status item, login item or an actual transfer.
    subprocess.run([str(executable), str(OUTPUT)], check=True)
