# SPDX-License-Identifier: GPL-3.0-only
import os
from pathlib import Path
import select
import socket
import sys
import time
import unittest
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Sources'))
from huawei_tcp import TCPListener
from huawei_runtime import Processes
from engine import Engine


class OwnedReceiveSocketTests(unittest.TestCase):
    def test_kernel_peer_and_bidirectional_protocol_descriptors(self):
        listener = TCPListener('127.0.0.1'); self.addCleanup(listener.close)
        with socket.create_connection(('127.0.0.1', listener.port), timeout=2) as client:
            client.sendall(b'offer')
            self.assertTrue(select.select([listener.stdout], [], [], 2)[0])
            self.assertEqual(listener.peer_address(), '127.0.0.1')
            self.assertEqual(listener.peer_address(), '127.0.0.1')
            self.assertEqual(os.read(listener.stdout.fileno(), 5), b'offer')
            listener.stdin.write(b'approval'); listener.stdin.flush()
            self.assertEqual(client.recv(8), b'approval')

    def test_cancellation_closes_both_pending_and_accepted_sockets(self):
        for connected in (False, True):
            with self.subTest(connected=connected):
                listener = TCPListener('127.0.0.1')
                children = Processes(); children.append(listener)
                if connected:
                    client = socket.create_connection(('127.0.0.1', listener.port), timeout=2)
                    self.addCleanup(client.close)
                    self.assertTrue(select.select([listener.stdout], [], [], 2)[0])
                    listener.peer_address()
                children.close(); children.close()
                self.assertEqual(listener.poll(), 0)
                self.assertEqual(listener.fileno(), -1)
                with self.assertRaises(ConnectionRefusedError):
                    socket.create_connection(('127.0.0.1', listener.port), timeout=2)
                if connected: self.assertEqual(client.recv(1), b'')


class IncomingPeerValidationTests(unittest.IsolatedAsyncioTestCase):
    async def test_undiscovered_socket_source_is_rejected_before_offer_parsing(self):
        engine = Engine(); runtime = engine.huawei
        runtime.peers['private'] = {'id': 'private', 'host': '127.0.0.2', 'last': time.monotonic(),
                                    'name': 'fixture', 'brand': 'Huawei', 'kind': 'phone'}
        listener = TCPListener('127.0.0.1'); children = Processes(); children.append(listener)
        with socket.create_connection(('127.0.0.1', listener.port), timeout=2) as client:
            self.assertTrue(select.select([listener.stdout], [], [], 2)[0])
            with patch.object(runtime, 'emit') as emit, patch('huawei_runtime.subprocess.run') as inspect:
                await runtime.receive(listener, children)
                inspect.assert_not_called()
                emit.assert_called_once_with('diagnostic', detail='huawei_incoming_rejected', phase='undiscovered_peer')
            self.assertEqual(client.recv(1), b'')
        self.assertEqual(listener.fileno(), -1)
