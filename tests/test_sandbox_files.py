"""Exercise real Foundation grants and engine failure/lifetime behavior."""
import asyncio
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import AsyncMock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Sources'))
from sandbox_files import BookmarkAccess, bookmarks_for
from engine import Engine


@unittest.skipUnless(sys.platform == 'darwin', 'Foundation required')
class FileGrantTests(unittest.TestCase):
    def test_only_default_downloads_can_be_configured_without_a_dynamic_grant(self):
        async def exercise():
            engine = Engine()
            with patch.dict(os.environ, {'ANDROP_SANDBOXED': '1'}), patch('engine.emit') as emit:
                downloads = str(Path.home() / 'Downloads')
                await engine.command({'command': 'configure', 'destination': downloads})
                self.assertEqual(engine.destination, downloads)
                self.assertFalse(any(c.args == ('error',) for c in emit.call_args_list))
                await engine.command({'command': 'configure', 'destination': '/a/custom/folder'})
                self.assertEqual(engine.destination, downloads)
                self.assertTrue(any(c.args == ('error',) for c in emit.call_args_list))
        asyncio.run(exercise())

    def test_roundtrip_and_mismatched_grant(self):
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder) / '選択.txt'
            other = Path(folder) / 'other.txt'
            source.write_text('fixture'); other.write_text('other')
            grants = bookmarks_for([source])
            with BookmarkAccess(grants, [source]) as access:
                self.assertEqual(len(access.urls), 1)
                self.assertEqual(source.read_text(), 'fixture')
            self.assertEqual(access.urls, [])
            with self.assertRaises(ValueError): BookmarkAccess(grants, [other])
            with self.assertRaises(ValueError): BookmarkAccess([], [source])
            with self.assertRaises(ValueError): BookmarkAccess(['invalid'], [source])

    def test_send_grant_lasts_until_send_finishes_and_closes_on_cancel(self):
        async def exercise():
            with tempfile.TemporaryDirectory() as folder:
                source = Path(folder) / 'source'; source.write_text('fixture')
                engine = Engine()
                started = asyncio.Event()
                async def send(*_):
                    started.set()
                    await asyncio.Event().wait()
                access = BookmarkAccess(bookmarks_for([source]), [source])
                with patch('engine.BookmarkAccess', return_value=access), patch.object(engine, 'send', side_effect=send):
                    task = asyncio.create_task(engine.command({'command': 'send', 'peer': 'fixture', 'paths': [str(source)], 'bookmarks': ['fixture']}))
                    await started.wait()
                    self.assertEqual(len(access.urls), 1)
                    task.cancel()
                    await asyncio.gather(task, return_exceptions=True)
                    self.assertEqual(access.urls, [])
        asyncio.run(exercise())

    def test_sandboxed_send_without_grant_reports_terminal_failure(self):
        async def exercise():
            engine = Engine()
            with patch.dict(os.environ, {'ANDROP_SANDBOXED': '1'}), patch.object(engine, 'send', new_callable=AsyncMock) as send, patch('engine.emit') as emit:
                await engine.command({'command': 'send', 'peer': 'fixture', 'paths': ['/dummy'], 'request_id': 'a' * 32})
                send.assert_not_awaited()
                failures = [call.kwargs for call in emit.call_args_list if call.args == ('transfer',)]
                self.assertEqual(len(failures), 1)
                self.assertEqual(failures[0]['state'], 'failed')
                self.assertEqual(failures[0]['id'], 'a' * 32)
        asyncio.run(exercise())
