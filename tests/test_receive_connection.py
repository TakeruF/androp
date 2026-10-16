# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 anDrop contributors

import asyncio, errno, ssl, sys, unittest
from pathlib import Path
from unittest.mock import AsyncMock, Mock, patch
from aiohttp import ClientConnectorError, ClientConnectorSSLError, WSServerHandshakeError
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'Sources'))
from engine import Engine, TransferError, connect_receive_channel, transfer_error_detail

class ReceiveConnectionTests(unittest.IsolatedAsyncioTestCase):
    async def test_reset_before_handshake_recovers_without_replaying_transfer(self):
        operation=AsyncMock(side_effect=[ClientConnectorError(None,ConnectionResetError(errno.ECONNRESET,'reset')),'channel'])
        diagnostic=Mock()
        with patch('engine.asyncio.sleep',new_callable=AsyncMock):
            self.assertEqual(await connect_receive_channel(operation,diagnostic),'channel')
        self.assertEqual(operation.await_count,2)
        self.assertEqual(diagnostic.call_args.kwargs['attempt'],2)

    async def test_not_ready_listener_recovers(self):
        operation=AsyncMock(side_effect=[ConnectionRefusedError(errno.ECONNREFUSED,'not ready'),'channel'])
        with patch('engine.asyncio.sleep',new_callable=AsyncMock):
            self.assertEqual(await connect_receive_channel(operation,Mock()),'channel')

    async def test_persistent_reset_is_bounded(self):
        operation=AsyncMock(side_effect=ConnectionResetError(errno.ECONNRESET,'reset'))
        with patch('engine.asyncio.sleep',new_callable=AsyncMock):
            with self.assertRaises(ConnectionResetError):await connect_receive_channel(operation,Mock())
        self.assertEqual(operation.await_count,4)

    async def test_tls_failure_is_fatal_without_protocol_downgrade(self):
        operation=AsyncMock(side_effect=ClientConnectorSSLError(None,ssl.SSLError('handshake')))
        with self.assertRaises(ClientConnectorSSLError):await connect_receive_channel(operation,Mock())
        self.assertEqual(operation.await_count,1)

    async def test_http_rejection_is_not_retried(self):
        operation=AsyncMock(side_effect=WSServerHandshakeError(None,(),status=403,message='not accepted'))
        with self.assertRaises(WSServerHandshakeError):await connect_receive_channel(operation,Mock())
        self.assertEqual(operation.await_count,1)

    async def test_permission_and_cancellation_are_not_retried(self):
        for error in [PermissionError(errno.EACCES,'denied'),asyncio.CancelledError()]:
            operation=AsyncMock(side_effect=error)
            with self.assertRaises(type(error)):await connect_receive_channel(operation,Mock())
            self.assertEqual(operation.await_count,1)

    async def test_active_receiver_is_not_expired_by_offer_timer(self):
        engine=Engine();session={'id':'test','state':'connecting','task':object()};engine.session=session
        with patch('engine.asyncio.sleep',new_callable=AsyncMock),patch('engine.emit') as events:
            await engine.expire_receive_offer(session,'central')
        self.assertIs(engine.session,session);events.assert_not_called()

    async def test_missing_connection_offer_still_expires(self):
        engine=Engine();session={'id':'test','direction':'receive','state':'connecting'};engine.session=session
        with patch('engine.asyncio.sleep',new_callable=AsyncMock),patch('engine.emit') as events:
            await engine.expire_receive_offer(session,'central')
        self.assertIsNone(engine.session)
        self.assertTrue(any(call.kwargs.get('state')=='failed' for call in events.call_args_list))

    def test_connection_errors_do_not_expose_endpoint_or_python_objects(self):
        error=ClientConnectorError(None,ConnectionResetError(errno.ECONNRESET,'example.invalid:1234 SSLContext object at hidden-address'))
        for language in ['en','zh']:
            with patch('engine.LANG',language):detail=transfer_error_detail(error)
            self.assertNotIn('example.invalid',detail);self.assertNotIn('SSLContext',detail);self.assertNotIn('hidden-address',detail)
            self.assertIn('closed the connection' if language=='en' else '断开了连接',detail)

    def test_unknown_failures_and_paths_do_not_escape_to_notifications(self):
        for error in [RuntimeError('private implementation detail'),FileNotFoundError('private filename')]:
            self.assertNotIn('private',transfer_error_detail(error))

    def test_missing_file_guidance_matches_transfer_direction(self):
        error=FileNotFoundError('private filename')
        self.assertIn('save folder',transfer_error_detail(error,receiving=True))
        self.assertIn('selected file',transfer_error_detail(error,receiving=False))

    def test_deliberate_user_message_is_preserved(self):
        self.assertEqual(transfer_error_detail(TransferError('Not enough free disk space.')),'Not enough free disk space.')

if __name__=='__main__':unittest.main()
