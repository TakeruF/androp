# SPDX-License-Identifier: GPL-3.0-only
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Sources'))
from received_files import mark_download, quarantine_value


class DownloadQuarantineTests(unittest.TestCase):
    def test_existing_os_quarantine_is_preserved_without_attempting_a_write(self):
        with patch('received_files.quarantine_value', return_value=b'0086;1234;OS;'), \
             patch('received_files.ctypes.CDLL') as library:
            mark_download('/synthetic/received')
            library.assert_not_called()

    def test_missing_quarantine_is_added_and_failed_marking_is_not_ignored(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'fixture.txt'; path.write_bytes(b'fixture')
            mark_download(path)
            self.assertTrue(int(quarantine_value(path).split(b';')[0], 16) & 3)
        with patch('received_files.quarantine_value', side_effect=OSError(93, 'missing')), \
             patch('received_files.ctypes.CDLL') as library:
            library.return_value.setxattr.return_value = -1
            with patch('received_files.ctypes.get_errno', return_value=1), self.assertRaises(PermissionError):
                mark_download('/synthetic/received')
