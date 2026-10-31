#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Exercise macOS's non-sandbox to sandbox migration with isolated dummy data."""
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]


def run(*args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, capture_output=True, **kwargs)


def main():
    identity = os.environ.get('ANDROP_SIGN_IDENTITY', '-')
    token = uuid.uuid4().hex
    bundle_id = 'org.androp.tests.migration.' + token
    leaf = 'anDrop-Migration-QA-' + token
    with tempfile.TemporaryDirectory(prefix='migration-', dir=ROOT / 'build') as temporary, \
         tempfile.TemporaryDirectory(prefix='anDrop-Migration-QA-', dir=Path.home() / 'Downloads') as output:
        root = Path(temporary)
        app = root / 'Migration.app'
        binary = app / 'Contents/MacOS/Migration'
        binary.parent.mkdir(parents=True)
        resources = app / 'Contents/Resources'; resources.mkdir()
        info = {
            'CFBundleIdentifier': bundle_id, 'CFBundleExecutable': 'Migration',
            'CFBundlePackageType': 'APPL', 'LSUIElement': True,
            'CFBundleVersion': '1', 'CFBundleShortVersionString': '1.0.0',
        }
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        source = root / 'Migration.swift'
        source.write_text(r'''
import AppKit

@main struct Migration {
    @MainActor static func main() throws {
        let mode = CommandLine.arguments[1], leaf = CommandLine.arguments[2]
        let resultURL = URL(fileURLWithPath: CommandLine.arguments[3])
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(leaf)
        let fixture = Data("persistent Huawei identity fixture".utf8)
        if mode == "seed" {
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            try fixture.write(to: support.appendingPathComponent("identity.pem"))
            defaults.set("trusted-fixture", forKey: "trustedDevices")
            defaults.set("history-fixture", forKey: "history")
            defaults.set("anDrop QA", forKey: "customSharingName")
            defaults.set(true, forKey: "trustedOnly")
            defaults.set(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path, forKey: "destination")
            defaults.synchronize()
            try Data("seeded".utf8).write(to: resultURL)
            return
        }
        var checks = [
            "container_home": NSHomeDirectory().contains("/Library/Containers/"),
            "identity_retained": (try? Data(contentsOf: support.appendingPathComponent("identity.pem"))) == fixture,
            "trusted_devices_retained": defaults.string(forKey: "trustedDevices") == "trusted-fixture",
            "history_retained": defaults.string(forKey: "history") == "history-fixture",
            "sharing_name_retained": defaults.string(forKey: "customSharingName") == "anDrop QA",
            "receive_scope_retained": defaults.bool(forKey: "trustedOnly"),
        ]
        let access = FileAccess()
        defer { access.close() }
        checks["legacy_downloads_restored"] = (try? access.restoreDestination(defaults: defaults)) != nil
        defaults.set("/a/legacy/custom/folder", forKey: "destination")
        do { _ = try access.restoreDestination(defaults: defaults); checks["custom_folder_requires_reselection"] = false }
        catch { checks["custom_folder_requires_reselection"] = true }
        try JSONSerialization.data(withJSONObject: checks, options: [.sortedKeys]).write(to: resultURL)
    }
}
''')
        run('swiftc', '-swift-version', '6', '-target', 'arm64-apple-macos14.0',
            '-parse-as-library', ROOT / 'Sources/FileAccess.swift', source, '-o', binary)
        run('codesign', '--force', '--sign', identity, '--options', 'runtime', app)
        result_path = Path(output) / 'result.json'
        run('open', '-n', '-W', app, '--args', 'seed', leaf, result_path)
        if result_path.read_text() != 'seeded': raise SystemExit('Legacy fixture did not launch')
        preferences = Path.home() / 'Library/Preferences' / (bundle_id + '.plist')
        expected = {'trustedDevices': 'trusted-fixture', 'history': 'history-fixture',
                    'customSharingName': 'anDrop QA', 'trustedOnly': True,
                    'destination': str(Path.home() / 'Downloads')}
        for _ in range(300):
            saved = plistlib.loads(preferences.read_bytes()) if preferences.exists() else {}
            if all(saved.get(key) == value for key, value in expected.items()): break
            time.sleep(.1)
        else: raise SystemExit('Legacy preferences were not durably saved')
        print(json.dumps({'legacy_preference_keys': sorted(plistlib.loads(preferences.read_bytes())),
                          'container_before_sandbox': (Path.home() / 'Library/Containers' / bundle_id).exists()}), flush=True)
        (resources / 'container-migration.plist').write_bytes(plistlib.dumps({
            'Move': ['${ApplicationSupport}/' + leaf],
        }))
        entitlements = root / 'sandbox.plist'
        entitlements.write_bytes(plistlib.dumps({
            'com.apple.security.app-sandbox': True,
            'com.apple.security.files.downloads.read-write': True,
            'com.apple.security.files.user-selected.read-write': True,
            'com.apple.security.files.bookmarks.app-scope': True,
        }))
        info['CFBundleVersion'] = '2'
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        run('codesign', '--force', '--sign', identity, '--options', 'runtime',
            '--entitlements', entitlements, app)
        run('open', '-n', '-W', app, '--args', 'verify', leaf, result_path)
        checks = json.loads(result_path.read_text())
        legacy = Path.home() / 'Library/Application Support' / leaf / 'identity.pem'
        checks['legacy_support_safe'] = not legacy.exists() or legacy.read_bytes() == b'persistent Huawei identity fixture'
        if not all(checks.values()): raise SystemExit(json.dumps(checks, indent=2))
        print(json.dumps({'checks': checks, 'passed': len(checks)}, indent=2))
        # The unique test container/preferences belong to macOS; do not remove them.


if __name__ == '__main__': main()
