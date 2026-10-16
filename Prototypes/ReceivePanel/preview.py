#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 anDrop contributors
"""Open the archived UI with in-memory state only; Escape exits the preview."""
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent
with tempfile.TemporaryDirectory(prefix='androp-panel-preview-') as temp:
    app = Path(temp) / 'ReceivePanelPreview.app/Contents'
    (app / 'MacOS').mkdir(parents=True)
    (app / 'Info.plist').write_bytes(plistlib.dumps({
        'CFBundleExecutable': 'ReceivePanelPreview',
        'CFBundleName': 'Receive Panel Preview',
        'CFBundleIdentifier': 'org.androp.prototype.receive-panel',
        'CFBundlePackageType': 'APPL',
    }))
    executable = app / 'MacOS/ReceivePanelPreview'
    subprocess.run([
        'swiftc', '-swift-version', '6', '-default-isolation', 'MainActor',
        '-parse-as-library', '-module-cache-path', str(Path(temp) / 'module-cache'),
        str(ROOT / 'ReceiveControlsView.swift'), str(ROOT / 'Preview.swift'),
        '-o', str(executable),
    ], check=True)
    subprocess.run([str(executable), *sys.argv[1:]], check=True)
