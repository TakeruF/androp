"""Offline boundaries for the standard-route investigation, never a live phone."""
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

spec = importlib.util.spec_from_file_location(
    'standard_research', Path(__file__).resolve().parents[1] /
    'scripts/research/huawei_standard_key_exchange.py')
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


class StandardResearchBoundaries(unittest.TestCase):
    def test_existing_identity_is_read_only_and_owner_only(self):
        from cryptography.hazmat.primitives.asymmetric import rsa
        from cryptography.hazmat.primitives.serialization import (
            Encoding, PrivateFormat, NoEncryption)
        key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        data = key.private_bytes(Encoding.PEM, PrivateFormat.PKCS8, NoEncryption())
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'synthetic.pem'
            with self.assertRaises(FileNotFoundError):
                probe.read_existing_identity(path)
            self.assertFalse(path.exists())
            path.write_bytes(data)
            path.chmod(0o600)
            self.assertEqual(probe.read_existing_identity(path).public_key().public_numbers(),
                             key.public_key().public_numbers())
            self.assertEqual(path.read_bytes(), data)
            link = Path(directory) / 'link.pem'
            link.symlink_to(path)
            with self.assertRaises(OSError):
                probe.read_existing_identity(link)
            path.chmod(0o644)
            with self.assertRaises(ValueError):
                probe.read_existing_identity(path)
            fifo = Path(directory) / 'fifo'
            os.mkfifo(fifo, 0o600)
            with self.assertRaises(ValueError):
                probe.read_existing_identity(fifo)

    def response(self, mode=b'0', key_material=b's' * 32):
        wrapped = AESGCM(b'k' * 32).encrypt(b'n' * 16, key_material, None)
        return probe.auth.tlv(23, mode) + probe.auth.tlv(19, wrapped)

    def test_transport_key_does_not_override_refusal(self):
        result = probe.key_response(self.response(), b'k' * 32, b'n' * 16)
        self.assertTrue(result['session_key_challenge_verified'])
        self.assertTrue(result['sharing_refused'])
        self.assertFalse(result['sharing_authorized'])
        self.assertNotIn(b's' * 32, repr(result).encode())

    def test_supported_verification_modes_still_need_verification(self):
        for mode in (b'1', b'2'):
            with self.subTest(mode=mode):
                result = probe.key_response(self.response(mode), b'k' * 32, b'n' * 16)
                self.assertTrue(result['further_verification_required'])
                self.assertFalse(result['sharing_authorized'])

    def test_rejects_tampering_wrong_nonce_and_wrong_key(self):
        original = self.response()
        for body, key, nonce in ((original[:-1] + bytes([original[-1] ^ 1]), b'k' * 32, b'n' * 16),
                                 (original, b'x' * 32, b'n' * 16),
                                 (original, b'k' * 32, b'x' * 16)):
            with self.subTest(key=key, nonce=nonce), self.assertRaises(InvalidTag):
                probe.key_response(body, key, nonce)

    def test_rejects_duplicate_unknown_and_invalid_key_responses(self):
        for body in (self.response() + probe.auth.tlv(23, b'1'), self.response(b'99'),
                     self.response(key_material=b's' * 16), self.response()[:-1]):
            with self.subTest(body_length=len(body)), self.assertRaises(ValueError):
                probe.key_response(body, b'k' * 32, b'n' * 16)

    def test_rejects_invalid_frames_before_decryption(self):
        good = probe.envelope(b'D' * 16, probe.auth.tlv(17, b'public'), 5, protocol=0)
        self.assertEqual(probe.parse_envelope(good), (0, 0, probe.auth.tlv(17, b'public')))
        for bad in (good[:10], b'bad!' + good[4:], good[:-1], good + b'x',
                    probe.auth.frame(8, 5, good[probe.auth.HEADER.size:]),
                    probe.envelope(b'D' * 16, b'x', 5, metadata=b'x' * 65)):
            with self.subTest(length=len(bad)), self.assertRaises(ValueError):
                probe.parse_envelope(bad)

    def test_rejects_excessive_field_count(self):
        with self.assertRaises(ValueError):
            probe.fields(probe.auth.tlv(1, b'x') * 33)


if __name__ == '__main__':
    unittest.main()
