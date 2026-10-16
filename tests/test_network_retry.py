# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 anDrop contributors

import asyncio, errno, sys, unittest
from pathlib import Path
from unittest.mock import AsyncMock, patch
from aiohttp import ClientConnectorError
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Sources'))
from engine import retry_local_route

class LocalRouteRetry(unittest.IsolatedAsyncioTestCase):
    async def test_transient_route_recovers(self):
        operation = AsyncMock(side_effect=[OSError(errno.EHOSTUNREACH, 'route'), 'connected'])
        with patch('engine.asyncio.sleep', new_callable=AsyncMock):
            self.assertEqual(await retry_local_route(operation), 'connected')
        self.assertEqual(operation.await_count, 2)

    async def test_aiohttp_wrapped_route_recovers(self):
        error = ClientConnectorError(None, OSError(errno.EHOSTUNREACH, 'route'))
        operation = AsyncMock(side_effect=[error, 'connected'])
        with patch('engine.asyncio.sleep', new_callable=AsyncMock):
            self.assertEqual(await retry_local_route(operation), 'connected')

    async def test_persistent_route_failure_is_bounded(self):
        operation = AsyncMock(side_effect=OSError(errno.EHOSTUNREACH, 'route'))
        with patch('engine.asyncio.sleep', new_callable=AsyncMock):
            with self.assertRaises(OSError): await retry_local_route(operation)
        self.assertEqual(operation.await_count, 4)

    async def test_permission_failure_is_not_retried(self):
        operation = AsyncMock(side_effect=PermissionError(errno.EACCES, 'denied'))
        with self.assertRaises(PermissionError): await retry_local_route(operation)
        self.assertEqual(operation.await_count, 1)

    async def test_cancellation_is_not_retried(self):
        operation = AsyncMock(side_effect=asyncio.CancelledError())
        with self.assertRaises(asyncio.CancelledError): await retry_local_route(operation)
        self.assertEqual(operation.await_count, 1)
