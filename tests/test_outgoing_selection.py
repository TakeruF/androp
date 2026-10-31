# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 anDrop contributors

"""Exercise real AppModel send commands and terminal events without a device."""
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('swiftc'), 'macOS Swift host required')
class OutgoingSelectionTests(unittest.TestCase):
    def test_new_sends_exclude_previous_batches(self):
        with tempfile.TemporaryDirectory(prefix='androp-selection-test-') as temp:
            stage = Path(temp)
            contents = stage / 'SelectionTests.app/Contents'
            executable = contents / 'MacOS/SelectionTests'
            executable.parent.mkdir(parents=True)
            (contents / 'Info.plist').write_bytes(plistlib.dumps({
                'CFBundleExecutable': executable.name,
                'CFBundleIdentifier': 'org.androp.tests.outgoing-selection',
                'CFBundlePackageType': 'APPL',
                'LSUIElement': True,
            }))
            # Keep the production model and views; isolate preferences/logs and
            # substitute Petal detection and window presentation at the OS boundary.
            source = (ROOT / 'Sources/main.swift').read_text()
            source, separator, _ = source.rpartition('\nconfigureBundleLanguage()\nlet app = NSApplication.shared')
            self.assertTrue(separator, 'Review application startup extraction')
            diagnostics = 'private let diagnostics = DiagnosticsStore(folder: '
            lines = source.splitlines()
            self.assertEqual(sum(diagnostics in line for line in lines), 1)
            source = '\n'.join(
                '    ' + diagnostics + 'URL(fileURLWithPath: CommandLine.arguments[1]))'
                if diagnostics in line else line for line in lines
            )
            source = source.replace('UserDefaults.standard', 'selectionTestDefaults')
            petal_detection = 'NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.EMUIInterconnect.app" }'
            self.assertEqual(source.count(petal_detection), 1)
            source = source.replace(petal_detection, 'petalTestRunning')
            presentation = 'NSApp.activate(ignoringOtherApps: true)\n            alert.window.makeKeyAndOrderFront(nil)'
            self.assertEqual(source.count(presentation), 1)
            source = source.replace(presentation, 'petalTestAlerts.append(alert)')
            notification = 'UNUserNotificationCenter.current().add(request)'
            self.assertEqual(source.count(notification), 1)
            source = source.replace(notification, 'selectionTestPostNotification(request)')
            source = ('let selectionTestDefaults = UserDefaults(suiteName: CommandLine.arguments[2])!\n'
                      'var petalTestRunning = false\nvar petalTestAlerts: [NSAlert] = []\n'
                      'var selectionTestNotifications: [(String, String)] = []\n'
                      'func selectionTestPostNotification(_ request: UNNotificationRequest, '
                      'completionHandler: @escaping @Sendable ((any Error)?) -> Void) {\n'
                      '    selectionTestNotifications.append((request.identifier, request.content.categoryIdentifier))\n'
                      '    completionHandler(nil)\n}\n'
                      + source)
            source += '\n' + (ROOT / 'tests/ui/OutgoingSelectionTests.swift').read_text()
            source += '\n' + (ROOT / 'tests/ui/TrustedHuaweiTests.swift').read_text()
            source += '\n' + (ROOT / 'tests/ui/PetalCoexistenceTests.swift').read_text()
            source += '\n' + (ROOT / 'tests/ui/NotificationExpiryTests.swift').read_text()
            generated = stage / 'main.swift'
            generated.write_text(source)
            localization = stage / 'Localization.swift'
            localization.write_text((ROOT / 'Sources/Localization.swift').read_text().replace(
                'UserDefaults.standard', 'selectionTestDefaults'))
            sources = ['AppUpdates.swift', 'FileAccess.swift', 'Localization.swift', 'Peer.swift',
                       'ReceiveAccessPolicy.swift', 'TransferProgress.swift',
                       'Diagnostics.swift', 'HuaweiLANDiscovery.swift', 'BrandLogos.swift',
                       'LivePhotoImporter.swift']
            compiled = subprocess.run([
                'swiftc', '-swift-version', '6', '-default-isolation', 'MainActor',
                '-module-cache-path', str(stage / 'module-cache'),
                *[str(localization if name == 'Localization.swift' else ROOT / 'Sources' / name) for name in sources],
                str(generated), '-o', str(executable),
            ], capture_output=True, text=True, timeout=180)
            self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
            # Redirect preference writes (history) to this disposable app domain.
            suite = 'org.androp.tests.outgoing-selection.' + stage.name
            executed = subprocess.run([
                str(executable), str(stage / 'diagnostics'), suite,
            ], capture_output=True, text=True, timeout=30)
            self.assertEqual(executed.returncode, 0, executed.stdout + executed.stderr)
            self.assertIn('Outgoing selection regression scenarios passed', executed.stdout)
            self.assertIn('Huawei trust regression scenarios passed', executed.stdout)
            self.assertIn('Petal coexistence regression scenarios passed', executed.stdout)
            self.assertIn('Notification expiry regression scenarios passed', executed.stdout)


if __name__ == '__main__':
    unittest.main()
