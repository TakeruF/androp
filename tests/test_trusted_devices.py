# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 anDrop contributors
import asyncio, base64, json, sys, unittest
from pathlib import Path
from unittest.mock import Mock, patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Sources'))
from engine import Engine, Keys

DEVICE = '00000000-0000-0000-0000-000000000001'
OTHER = '00000000-0000-0000-0000-000000000002'

def offer(engine, identifier=DEVICE, name='Same account name'):
    keys = Keys(); keys.derive(engine.keys.public)
    payload = {'key': keys.public, 'number': keys.encrypt('1'), 'device_name': keys.encrypt(name)}
    return {'uuid': '9896', 'central': identifier, 'data': base64.b64encode(json.dumps(payload).encode()).decode()}

class TrustedDeviceTests(unittest.IsolatedAsyncioTestCase):
    async def test_unknown_sender_rejected_before_key_exchange_or_confirmation(self):
        engine = Engine(); engine.trusted_only = True; engine.trusted_ids = {DEVICE}
        with patch.object(engine.keys, 'derive') as derive, patch('engine.emit') as emit:
            await engine.receive_write(offer(engine, OTHER))
        derive.assert_not_called()
        self.assertIsNone(engine.session)
        self.assertFalse(any(c.args[0] == 'transfer' for c in emit.call_args_list))

    async def test_trusted_sender_still_needs_approval_and_identity_is_forwarded(self):
        engine = Engine(); engine.trusted_only = True; engine.trusted_ids = {DEVICE}
        with patch('engine.emit') as emit:
            task = asyncio.create_task(engine.receive_write(offer(engine)))
            await asyncio.sleep(0)
            self.assertEqual(engine.session['state'], 'request')
            self.assertEqual(next(c.kwargs['device_identifier'] for c in emit.call_args_list if c.args[0] == 'transfer'), DEVICE)
            engine.decisions[engine.session['id']].set_result(False)
            await task
        self.assertIsNone(engine.session)

    async def test_revoking_trust_while_confirmation_pending_blocks_accept(self):
        engine = Engine(); engine.trusted_only = True; engine.trusted_ids = {DEVICE}
        with patch('engine.emit') as emit:
            task = asyncio.create_task(engine.receive_write(offer(engine)))
            await asyncio.sleep(0)
            engine.trusted_ids.clear()
            engine.decisions[engine.session['id']].set_result(True)
            await task
        self.assertIsNone(engine.session)
        self.assertFalse(any(c.kwargs.get('state') == 'connecting' for c in emit.call_args_list))

    async def test_everyone_still_needs_approval(self):
        engine = Engine()
        with patch('engine.emit'):
            task = asyncio.create_task(engine.receive_write(offer(engine, OTHER)))
            await asyncio.sleep(0)
            self.assertEqual(engine.session['state'], 'request')
            engine.decisions[engine.session['id']].set_result(False)
            await task

    def test_names_do_not_grant_trust_and_empty_list_is_closed(self):
        engine = Engine(); engine.trusted_only = True
        self.assertFalse(engine.may_receive(DEVICE))
        self.assertFalse(engine.may_receive(''))
        engine.trusted_ids = {DEVICE}
        self.assertTrue(engine.may_receive(DEVICE.lower()))
        self.assertFalse(engine.may_receive(OTHER))

    async def test_unknown_subscription_receives_no_ready_notification(self):
        engine = Engine(); engine.trusted_only = True; engine.trusted_ids = {DEVICE}
        with patch('engine.emit') as emit:
            await engine.command({'command':'subscribe','uuid':'9895','central':OTHER})
            await engine.command({'command':'subscribe','uuid':'9895'})
        self.assertFalse(any(c.args[0] == 'ble_notify' for c in emit.call_args_list))

    async def test_trusted_subscription_gets_ready_but_disabled_receiver_does_not(self):
        engine = Engine(); engine.trusted_only = True; engine.trusted_ids = {DEVICE}
        with patch('engine.emit') as emit:
            await engine.command({'command':'subscribe','uuid':'9895','central':DEVICE})
        self.assertEqual(sum(c.args[0] == 'ble_notify' for c in emit.call_args_list), 1)
        engine.scan_enabled = False
        with patch('engine.emit') as emit:
            await engine.command({'command':'subscribe','uuid':'9895','central':DEVICE})
        self.assertFalse(any(c.args[0] == 'ble_notify' for c in emit.call_args_list))

    def test_accepted_session_retains_control_access_after_trust_removal(self):
        engine = Engine(); engine.trusted_only = True
        engine.session = {'direction':'receive','state':'connecting','central':DEVICE}
        self.assertTrue(engine.may_access_control(DEVICE.lower()))
        self.assertFalse(engine.may_access_control(OTHER))
        self.assertFalse(engine.may_receive(DEVICE))  # New offers remain blocked.
        engine.session['state'] = 'request'
        self.assertFalse(engine.may_access_control(DEVICE))
        engine.session = None
        self.assertFalse(engine.may_access_control(DEVICE))
