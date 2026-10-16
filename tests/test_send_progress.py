# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 anDrop contributors

import asyncio, sys, tempfile, unittest, uuid, zipfile
from pathlib import Path
from unittest.mock import AsyncMock, patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'Sources'))
from engine import Engine, stream_archive

class SendProgressTests(unittest.IsolatedAsyncioTestCase):
    async def test_progress_counts_zip_bytes_including_empty_file_and_overhead(self):
        with tempfile.TemporaryDirectory() as folder:
            archive=Path(folder)/'files.zip'
            with zipfile.ZipFile(archive,'w',zipfile.ZIP_STORED) as z:
                z.writestr('empty.txt',b'');z.writestr('sample.bin',b'x'*(2*1024*1024+37))
            response=AsyncMock();updates=[]
            total=await stream_archive(response,archive,lambda n,t:updates.append((n,t)))
            self.assertGreater(total,2*1024*1024+37)
            self.assertEqual(updates[0],(0,total));self.assertEqual(updates[-1],(total,total))
            self.assertTrue(all(a[0]<b[0] for a,b in zip(updates,updates[1:])))
            self.assertEqual(sum(len(call.args[0]) for call in response.write.await_args_list),total)
            response.write_eof.assert_awaited_once()

    async def test_an_empty_payload_still_has_measurable_transport_progress(self):
        with tempfile.TemporaryDirectory() as folder:
            archive=Path(folder)/'empty.zip'
            with zipfile.ZipFile(archive,'w') as z:z.writestr('empty.txt',b'')
            updates=[]
            total=await stream_archive(AsyncMock(),archive,lambda n,t:updates.append((n,t)))
            self.assertGreater(total,0);self.assertEqual(updates,[(0,total),(total,total)])

    async def test_failed_write_does_not_count_unsent_chunk_or_finish(self):
        with tempfile.TemporaryDirectory() as folder:
            archive=Path(folder)/'sample';archive.write_bytes(b'x'*(2*1024*1024))
            response=AsyncMock();response.write.side_effect=[None,ConnectionResetError()];updates=[]
            with self.assertRaises(ConnectionResetError):
                await stream_archive(response,archive,lambda n,t:updates.append((n,t)))
            self.assertEqual(updates[-1][0],1024*1024);response.write_eof.assert_not_awaited()

    async def test_cancelled_stream_does_not_emit_full_progress(self):
        with tempfile.TemporaryDirectory() as folder:
            archive=Path(folder)/'sample';archive.write_bytes(b'example')
            response=AsyncMock();response.write.side_effect=asyncio.CancelledError();updates=[]
            with self.assertRaises(asyncio.CancelledError):
                await stream_archive(response,archive,lambda n,t:updates.append((n,t)))
            self.assertEqual(updates,[(0,7)]);response.write_eof.assert_not_awaited()

    async def test_rejected_send_preserves_request_identity(self):
        identifier=uuid.uuid4().hex;engine=Engine()
        with patch('engine.emit') as events:
            await engine.send('gone',[],request_id=identifier)
        self.assertEqual(events.call_args.kwargs['id'],identifier)
        self.assertEqual(events.call_args.kwargs['state'],'failed')
        self.assertIsNone(engine.session)

    async def test_busy_rejection_does_not_replace_current_transfer(self):
        engine=Engine();current={'id':'existing'};engine.session=current
        with patch('engine.emit') as events:
            await engine.send('other',[],request_id='12345678123456781234567812345678')
        self.assertIs(engine.session,current)
        self.assertEqual(events.call_args.kwargs['state'],'failed')

    def test_sending_all_bytes_is_not_a_receiver_completion(self):
        engine=Engine();session={'id':'test','direction':'send'}
        with patch('engine.emit') as events:engine.progress(session,100,100)
        self.assertEqual(events.call_args.kwargs['state'],'transferring')
        self.assertNotEqual(session['state'],'complete')

if __name__=='__main__':unittest.main()
