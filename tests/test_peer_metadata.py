# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 anDrop contributors

import sys, unittest
from pathlib import Path
from types import SimpleNamespace
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Sources'))
from peer_metadata import parse_peer_metadata, peer_identifier
from engine import Engine, bu

class PeerMetadataTests(unittest.TestCase):
    def test_phone_and_tablet_same_account_stay_separate(self):
        engine = Engine(); engine.discovering = True
        for identifier, flags, advertised_id in [('phone-endpoint', 9, '112233445566'), ('tablet-endpoint', 11, '223344556677')]:
            ad = SimpleNamespace(service_data={bu('3333'): f'{advertised_id}-r--1-11-{flags}'.encode(), bu('3334'): b'Shared account'}, local_name=None)
            engine.discovered(SimpleNamespace(address=identifier), ad)
        self.assertEqual(len(engine.peers), 2)
        self.assertEqual(engine.peers['mta11:112233445566']['kind'], 'phone')
        self.assertEqual(engine.peers['mta11:223344556677']['kind'], 'tablet')
        self.assertEqual(engine.peers['mta11:112233445566']['brand'], 'OPPO')
        self.assertEqual(engine.peers['mta11:223344556677']['brand'], 'OPPO')

    def test_unknown_or_conflicting_metadata_is_not_guessed(self):
        for raw in [None, '', 'bad', 'id-r--1-12-9', 'id-r--1-11-0',
                    'id-r--1-11-25', 'id-r--1-11-999999', 'id-r--1-11--1',
                    'id-r--1-11-９', 'id-s--1-11-9', 'id-r--1-11-9-extra']:
            self.assertEqual(parse_peer_metadata(raw), {}, raw)

    def test_realme_and_receiver_roles(self):
        self.assertEqual(parse_peer_metadata('id-sr--1-11-17'), {'brand':'realme','kind':'phone'})
        self.assertEqual(parse_peer_metadata('id-r--1-11-19'), {'brand':'realme','kind':'tablet'})

    def test_rediscovery_refreshes_metadata_without_duplicate(self):
        engine = Engine(); engine.discovering = True
        device = SimpleNamespace(address='same-endpoint')
        for label in [b'Before', b'After']:
            engine.discovered(device, SimpleNamespace(service_data={bu('3333'): b'000000000000-r--1-11-9',bu('3334'):label},local_name=None))
        self.assertEqual(len(engine.peers), 1)
        self.assertEqual(engine.peers[device.address]['name'], 'After')

    def test_address_rotation_keeps_one_recipient_and_updates_route(self):
        engine = Engine(); engine.discovering = True
        ad = SimpleNamespace(service_data={bu('3333'): b'112233445566-r--1-11-9', bu('3334'): b'Shared account'}, local_name=None)
        first, second = SimpleNamespace(address='old-route'), SimpleNamespace(address='new-route')
        engine.discovered(first, ad)
        engine.discovered(second, ad)
        self.assertEqual(len(engine.peers), 1)
        self.assertIs(engine.devices['mta11:112233445566'], second)

    def test_invalid_or_unknown_identity_uses_endpoint(self):
        for identity in [None, '', '000000000000-r--1-11-9', '112233445566-r--1-12-9', 'not-an-id-r--1-11-9']:
            self.assertEqual(peer_identifier(identity, 'endpoint'), 'endpoint')

if __name__ == '__main__': unittest.main()
