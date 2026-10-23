"""Check production share-error layout without launching Photos or the engine."""
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('swiftc'), 'macOS Swift host required')
class ShareExtensionLayoutTests(unittest.TestCase):
    def test_error_text_wraps_without_covering_close_button(self):
        with tempfile.TemporaryDirectory(prefix='androp-share-view-test-') as temp:
            stage = Path(temp)
            contents = stage / 'ShareViewTests.app/Contents'
            executable = contents / 'MacOS/ShareViewTests'
            executable.parent.mkdir(parents=True)
            (contents / 'Info.plist').write_bytes(plistlib.dumps({
                'CFBundleExecutable': executable.name,
                'CFBundleIdentifier': 'org.androp.tests.share-view',
                'CFBundlePackageType': 'APPL', 'LSUIElement': True,
            }))
            source = (ROOT / 'Sources/ShareViewController.swift').read_text()
            source += r'''
extension ShareViewController {
    func exerciseErrorLayout() throws {
        loadViewIfNeeded()
        for message in [
            "无法读取共享文件。请重新共享，或导出后使用 anDrop 的发送文件功能。不支持 URL 或文本共享。",
            "Could not read the shared file. Share it again or export it and use Send Files in anDrop. URL and text sharing are not supported."
        ] {
            titleLabel.stringValue = message
            view.needsUpdateConstraints = true
            view.updateConstraintsForSubtreeIfNeeded()
            view.window?.layoutIfNeeded()
            view.layoutSubtreeIfNeeded()
            precondition(!titleLabel.usesSingleLineMode && titleLabel.cell?.wraps == true)
            let textBounds = titleLabel.alignmentRect(forFrame: titleLabel.frame)
            precondition(textBounds.width <= view.bounds.width - 47)
            precondition(titleLabel.frame.height >= 30)
            let close = view.subviews.compactMap { $0 as? NSButton }.first!
            precondition(titleLabel.frame.minY >= close.frame.maxY + 19)
        }
    }
}
let testApp = NSApplication.shared
testApp.setActivationPolicy(.accessory)
let controller = ShareViewController()
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 210), styleMask: [.titled], backing: .buffered, defer: false)
window.contentViewController = controller
try controller.exerciseErrorLayout()
print("Share extension wrapping and close-button layout passed")
'''
            main = stage / 'main.swift'
            main.write_text(source)
            built = subprocess.run(['swiftc', '-swift-version', '6', '-default-isolation', 'MainActor',
                                    str(ROOT / 'Sources/Localization.swift'),
                                    str(ROOT / 'Sources/SharedFileStaging.swift'), str(main),
                                    '-o', str(executable)], capture_output=True, text=True, timeout=120)
            self.assertEqual(built.returncode, 0, built.stderr)
            rendered = subprocess.run([str(executable)],
                                      capture_output=True, text=True, timeout=30)
            self.assertEqual(rendered.returncode, 0, rendered.stderr)
            self.assertIn('layout passed', rendered.stdout)
