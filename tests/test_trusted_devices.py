# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 anDrop contributors
import asyncio, base64, json, sys, unittest
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Sources'))
from engine import Engine, Keys, sender_identifier, valid_trust_identifier

DEVICE = '00000000-0000-0000-0000-000000000001'
OTHER = '00000000-0000-0000-0000-000000000002'
SENDER = 'synthetic-device-a'
IDENTITY = sender_identifier(SENDER)

def offer(engine, identifier=DEVICE, name='Same account name'):
    keys = Keys(); keys.derive(engine.keys.public)
    payload = {'key': keys.public, 'number': keys.encrypt('1'), 'device_name': keys.encrypt(name)}
    return {'uuid': '9896', 'central': identifier, 'data': base64.b64encode(json.dumps(payload).encode()).decode()}

class TrustedDeviceTests(unittest.IsolatedAsyncioTestCase):
    async def asyncTearDown(self):
        for task in asyncio.all_tasks():
            if task is not asyncio.current_task(): task.cancel()

    async def test_empty_trust_list_rejects_before_key_exchange(self):
        engine = Engine(); engine.trusted_only = True
        with patch.object(engine.keys,'derive') as derive, patch('engine.emit'):
            await engine.receive_write(offer(engine,OTHER))
        derive.assert_not_called();self.assertIsNone(engine.session)

    async def test_rotated_address_can_negotiate_but_not_receive_before_identity_check(self):
        engine=Engine();engine.trusted_only=True;engine.trusted_ids={IDENTITY}
        with patch('engine.emit') as events:
            await engine.receive_write(offer(engine,OTHER))
        self.assertEqual(engine.session['state'],'verifying')
        self.assertEqual(engine.decisions,{})
        self.assertFalse(any(c.kwargs.get('state')=='request' for c in events.call_args_list))

    async def approve(self, engine, sender=SENDER, decision=True, mutate=None):
        session={'id':'session','direction':'receive','central':OTHER,'count':1,'peer':'Same account name'};engine.session=session
        with patch('engine.emit'):
            task=asyncio.create_task(engine.approve_receive(session,{'senderId':sender,'fileName':'test.txt','totalSize':5}))
            await asyncio.sleep(0)
            if mutate:mutate()
            if engine.decisions:engine.decisions['session'].set_result(decision)
            return await task

    async def test_rotated_trusted_sender_requires_user_approval(self):
        for decision in [True,False]:
            engine=Engine();engine.trusted_only=True;engine.trusted_ids={IDENTITY}
            engine.auto_accept_trusted=False
            self.assertEqual(await self.approve(engine,decision=decision),decision)
            self.assertEqual(engine.session['device_identifier'],IDENTITY)

    async def test_same_name_different_sender_id_is_denied(self):
        engine=Engine();engine.trusted_only=True;engine.trusted_ids={IDENTITY}
        self.assertFalse(await self.approve(engine,sender='synthetic-device-b'))
        self.assertEqual(engine.decisions,{})

    async def test_missing_id_cannot_inherit_stable_trust(self):
        engine=Engine();engine.trusted_only=True;engine.trusted_ids={IDENTITY}
        self.assertFalse(await self.approve(engine,sender=None))

    async def test_revocation_and_disable_while_confirming_win_over_acceptance(self):
        for change in ['revoke','disable']:
            engine=Engine();engine.trusted_only=True;engine.trusted_ids={IDENTITY}
            engine.auto_accept_trusted=False
            def mutate():
                if change=='revoke':engine.trusted_ids.clear()
                else:engine.scan_enabled=False
            self.assertFalse(await self.approve(engine,mutate=mutate))

    async def test_everyone_still_requires_acceptance(self):
        for decision in [True,False]:self.assertEqual(await self.approve(Engine(),decision=decision),decision)

    async def test_trusted_sender_is_automatically_accepted_by_default_in_both_scopes(self):
        for trusted_only in (False, True):
            engine=Engine();engine.trusted_only=trusted_only;engine.trusted_ids={IDENTITY}
            with patch.object(engine,'update') as update:
                self.assertTrue(await self.approve(engine,decision=False))
            update.assert_not_called()
            self.assertEqual(engine.decisions,{})

    async def test_turning_auto_accept_off_requires_approval_in_both_scopes(self):
        for trusted_only in (False, True):
            for decision in (False, True):
                engine=Engine();engine.trusted_only=trusted_only;engine.trusted_ids={IDENTITY}
                engine.auto_accept_trusted=False
                self.assertEqual(await self.approve(engine,decision=decision),decision)

    async def test_auto_accept_does_not_bypass_disabled_receiving_or_removed_trust(self):
        for trusted_only in (False, True):
            engine=Engine();engine.trusted_only=trusted_only;engine.trusted_ids={IDENTITY}
            engine.scan_enabled=False
            self.assertFalse(await self.approve(engine))
            engine.scan_enabled=True;engine.trusted_ids.clear()
            self.assertFalse(await self.approve(engine,decision=False))

    async def test_auto_accept_configuration_defaults_on_and_can_be_toggled(self):
        engine=Engine()
        with patch('engine.emit'):
            for value in (None,False,True):
                configuration={'command':'configure','trusted_ids':[IDENTITY]}
                if value is not None:configuration['auto_accept_trusted']=value
                await engine.command(configuration)
                self.assertEqual(engine.auto_accept_trusted,value is not False)
                self.assertEqual(await self.approve(engine,decision=False),value is not False)

    async def test_legacy_uuid_cannot_match_another_role_or_rotated_address(self):
        engine=Engine();engine.trusted_only=True;engine.trusted_ids={DEVICE}
        self.assertFalse(engine.may_negotiate(OTHER))
        self.assertTrue(engine.may_negotiate(DEVICE))
        self.assertFalse(await self.approve(engine))

    async def test_invalid_configuration_ids_are_ignored_without_breaking_engine(self):
        engine=Engine()
        with patch('engine.emit'):
            await engine.command({'command':'configure','trusted_only':True,'trusted_ids':[None,123,'x'*36,IDENTITY,DEVICE.lower()]})
        self.assertEqual(engine.trusted_ids,{IDENTITY,DEVICE})

    def test_hash_is_stable_private_and_not_a_display_name_fallback(self):
        self.assertEqual(sender_identifier(SENDER),IDENTITY)
        self.assertNotIn(SENDER,IDENTITY)
        for value in [None,'','a',' ','1234567\n',' padded-id','id with space',42,'a'*257]:self.assertIsNone(sender_identifier(value))
        for value in [IDENTITY,DEVICE]:self.assertEqual(valid_trust_identifier(value),value)

    def test_negotiation_does_not_grant_file_authorization(self):
        engine=Engine();engine.trusted_only=True;engine.trusted_ids={IDENTITY}
        self.assertTrue(engine.may_access_control(OTHER))
        self.assertFalse(engine.may_receive(OTHER))
        self.assertTrue(engine.may_receive(OTHER,IDENTITY))
        engine.scan_enabled=False
        self.assertFalse(engine.may_access_control(OTHER))

    async def test_malformed_write_from_another_device_cannot_abort_active_transfer(self):
        engine=Engine();session={'id':'active','central':DEVICE,'direction':'receive','state':'transferring'};engine.session=session
        with patch('engine.emit'):
            await engine.command({'command':'write','central':OTHER,'uuid':'9896','data':'not valid base64'})
        self.assertIs(engine.session,session)
        self.assertEqual(session['state'],'transferring')
