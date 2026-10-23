# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 anDrop contributors

import asyncio, errno, ssl, sys, unittest
from pathlib import Path
from unittest.mock import AsyncMock, Mock, patch
from aiohttp import ClientConnectorError, ClientConnectorSSLError, WSServerHandshakeError
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'Sources'))
from engine import Engine, TransferError, connect_receive_channel, connection_error_fields, transfer_error_detail, control_message
from aiohttp import WSMessage, WSMsgType

class ReceiveConnectionTests(unittest.IsolatedAsyncioTestCase):
    def test_missing_errno_classification_is_finite_and_never_includes_messages(self):
        examples=[('no matching local address with family=<AddressFamily.AF_INET6: 30> found','local_address_family_mismatch'),
                  ('Multiple exceptions: private endpoint, private path','multiple_socket_errors'),
                  ('no interface with this name: private interface','interface_unavailable'),
                  ('unknown private host 192.168.3.9:4567 /Users/private','errno_unavailable'),
                  ('private prefix no matching local address with family=30','errno_unavailable')]
        for message,expected in examples:
            with self.subTest(expected=expected):
                wrapped=ClientConnectorError(None,OSError(message))
                self.assertEqual(connection_error_fields(wrapped),{'connection_issue':expected})

    def test_errno_is_numeric_bounded_and_takes_priority_over_issue(self):
        for number in [errno.ECONNRESET,errno.EACCES,-2]:
            error=ClientConnectorError(None,OSError(number,'Multiple exceptions: private endpoint'))
            self.assertEqual(connection_error_fields(error),{'errno':number})
        for number in [True,65536,-65536,'private endpoint']:
            error=RuntimeError('unknown private data');error.errno=number
            self.assertEqual(connection_error_fields(error),{'connection_issue':'errno_unavailable'})

    def test_nested_metadata_cycles_and_depth_are_bounded_without_stringification(self):
        class PrivateError(OSError):
            def __str__(self):raise AssertionError('Do not stringify private errors')
        nested=PrivateError('no matching local address with family=30 found')
        wrapped=ClientConnectorError(None,nested)
        wrapped.__cause__=nested;nested.__context__=wrapped
        self.assertEqual(connection_error_fields(wrapped),{'connection_issue':'local_address_family_mismatch'})
        error=RuntimeError('private wrapper');error.__cause__=OSError(errno.EHOSTUNREACH,'private endpoint')
        self.assertEqual(connection_error_fields(error),{'errno':errno.EHOSTUNREACH})
        error=RuntimeError('private root');tail=error
        for _ in range(100):
            tail.__cause__=RuntimeError('private nested');tail=tail.__cause__
        tail.__cause__=OSError(errno.EACCES,'private endpoint')
        self.assertEqual(connection_error_fields(error),{'connection_issue':'errno_unavailable'})

    async def test_missing_errno_connect_failure_is_classified_without_new_retry(self):
        error=ClientConnectorError(None,OSError('no matching local address with family=30 found private host'))
        operation=AsyncMock(side_effect=error);diagnostic=Mock()
        with patch('engine.asyncio.sleep',new_callable=AsyncMock) as sleep:
            with self.assertRaises(ClientConnectorError):await connect_receive_channel(operation,diagnostic)
        self.assertEqual(operation.await_count,1);sleep.assert_not_awaited()
        diagnostic.assert_any_call('receive_connect_interrupted',error_type='ClientConnectorError',connection_issue='local_address_family_mismatch')
        self.assertNotIn('private',str(diagnostic.call_args_list))

    async def test_receive_terminal_connection_diagnostic_uses_same_safe_fields(self):
        engine=Engine();engine.notify=Mock();engine.reset=AsyncMock();engine.update=Mock()
        session={'id':'synthetic-transfer','central':'synthetic-central','local_address':'192.0.2.1'}
        error=ClientConnectorError(None,OSError('Multiple exceptions: private host:4567 /Users/private'))
        with patch('engine.TCPConnector',side_effect=error),patch('engine.emit') as events:
            await engine.receive(session,'192.0.2.2',4567,None)
        events.assert_any_call('diagnostic',detail='receive_failed',transfer_id='synthetic-transfer',phase='connect',
                               error_type='ClientConnectorError',connection_issue='multiple_socket_errors')
        self.assertNotIn('private',str(events.call_args_list))
        engine.update.assert_any_call(session,'failed',detail=unittest.mock.ANY)
        engine.reset.assert_awaited_once_with(session)

    async def test_network_offer_carries_transfer_id_and_existing_mode_only(self):
        for is_lan,mode in [(True,'lan'),(False,'direct')]:
            engine=Engine();engine.notify=Mock()
            session={'id':'synthetic-transfer','central':'synthetic-central','keys':Mock()};engine.session=session
            def launch(coroutine):
                coroutine.close()
                return Mock()
            engine.launch=Mock(side_effect=launch)
            with patch('engine.local_endpoint',return_value='192.0.2.1'),patch('engine.interface_for_address',return_value=None),\
                 patch('engine.bind_interface'),patch('engine.socket.socket'),patch('engine.emit') as events:
                await engine.replace_receive_route(session,'192.0.2.2',4567,is_lan)
            events.assert_any_call('diagnostic',detail='receive_network_offer',transfer_id='synthetic-transfer',mode=mode)

    def test_control_close_reports_connection_error_without_parsing_private_reason(self):
        diagnostic=Mock()
        with self.assertRaises(ConnectionError):control_message(WSMessage(WSMsgType.CLOSE,1000,'private reason'),diagnostic)
        diagnostic.assert_called_once_with('control_message',message_type='close')

    def test_binary_control_rejects_non_utf8_and_oversized_payloads(self):
        for data in [b'\xff',b'x'*131073]:
            with self.assertRaises((ValueError,UnicodeDecodeError)):
                control_message(WSMessage(WSMsgType.BINARY,data,''),Mock())

    def test_control_diagnostics_never_emit_unknown_action_or_payload_values(self):
        diagnostic=Mock()
        control_message(WSMessage(WSMsgType.TEXT,'action:1:private@example.invalid?{"ip":"192.168.3.9"}',''),diagnostic)
        diagnostic.assert_any_call('control_action',protocol_action='other')
        self.assertNotIn('private',str(diagnostic.call_args_list))
        self.assertNotIn('192.168',str(diagnostic.call_args_list))

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
