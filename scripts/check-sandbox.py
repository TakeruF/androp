#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Verify the concrete signed host, extension, inherited tools and updater."""
import argparse
import json
from pathlib import Path
import plistlib
import subprocess


def entitlements(path):
    result = subprocess.run(['codesign', '-d', '--entitlements', ':-', str(path)],
                            check=True, capture_output=True)
    return plistlib.loads(result.stdout)


def require(condition, message):
    if not condition: raise SystemExit(message)


def check(app):
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    config = json.loads((Path(__file__).resolve().parents[1] / 'release.json').read_text())
    migration = app / 'Contents/Resources/container-migration.plist'
    if info['CFBundleIdentifier'] == config['bundle_identifier']:
        require(migration.is_file() and plistlib.loads(migration.read_bytes()) == {
            'Move': ['${ApplicationSupport}/anDrop'],
        }, 'Production support-data migration missing or changed')
    else:
        require(not migration.exists(), 'Isolated build must not migrate production support data')
    host = entitlements(app)
    required = {'com.apple.security.app-sandbox', 'com.apple.security.device.bluetooth',
                'com.apple.security.network.client', 'com.apple.security.network.server',
                'com.apple.security.files.downloads.read-write',
                'com.apple.security.files.user-selected.read-write',
                'com.apple.security.files.bookmarks.app-scope'}
    require(all(host.get(key) is True for key in required), 'Missing host sandbox entitlement')
    exceptions = 'com.apple.security.temporary-exception.mach-lookup.global-name'
    require(set(host) == required | ({exceptions} if 'SUFeedURL' in info else set()), 'Unexpected host entitlements')
    inherited = {'com.apple.security.app-sandbox': True, 'com.apple.security.inherit': True}
    for relative in ['Contents/Resources/Engine/anDropEngine', 'Contents/MacOS/anDropLivePhoto']:
        require(entitlements(app / relative) == inherited, f'Invalid sandbox inheritance: {relative}')
    require(entitlements(app / 'Contents/PlugIns/anDropShare.appex') == {
        'com.apple.security.app-sandbox': True, 'com.apple.security.files.user-selected.read-only': True,
    }, 'Share extension rights changed')
    if 'SUFeedURL' in info:
        require(info.get('SUEnableInstallerLauncherService') is True, 'Sparkle installer service disabled')
        require(not info.get('SUEnableDownloaderService'), 'Unnecessary downloader service')
        require(host.get(exceptions) == [info['CFBundleIdentifier'] + '-spks', info['CFBundleIdentifier'] + '-spki'], 'Invalid Sparkle service names')
        require((app / 'Contents/Frameworks/Sparkle.framework/XPCServices/Installer.xpc').is_dir(), 'Missing Sparkle installer')
    else:
        require(not (app / 'Contents/Frameworks/Sparkle.framework').exists(), 'Store build includes Sparkle')
    print('App Sandbox verified: signed host, share extension, engine, converter and updater configuration.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    check(parser.parse_args().app)
