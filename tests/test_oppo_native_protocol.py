"""Offline synthetic protocol fixtures only: no Bluetooth, sockets, or devices."""
import base64
import importlib.util
from pathlib import Path
import struct
import sys
import unittest

MODULE = Path(__file__).resolve().parents[1] / 'scripts/research/oppo_native_protocol.py'
spec = importlib.util.spec_from_file_location('oppo_native_protocol', MODULE)
p = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = p
spec.loader.exec_module(p)


class NativeProtocolTests(unittest.TestCase):
    def test_exact_native_go_request_and_read(self):
        self.assertEqual(p.encode_go_request('02:00:00:00:00:01'), b'11&020000000001&1')
        info = p.parse_native_read(b'020000000001&3')
        self.assertEqual((info.mac, info.version, info.public_key), ('020000000001', 3, None))
        self.assertEqual(p.UUIDS['native_read'], '00009996-0000-1000-8000-00805f9b34fb')
        for raw in [b'020000000001|3', b'BAD&3', b'020000000001&0', b'x' * 4097]:
            with self.subTest(length=len(raw)), self.assertRaises(p.ProtocolError):
                p.parse_native_read(raw)

    def test_go_response_default_and_random_ports(self):
        raw = b'0200000000013&2412&DIRECT-AB-Synthetic&synthetic-psk&20001'
        slices = [raw[i:i+22] for i in range(0, len(raw), 22)]
        self.assertLessEqual(len(slices), 3)
        info = p.parse_go_handover(b''.join(slices))
        self.assertEqual((info.ssid, info.psk, info.port), ('DIRECT-AB-Synthetic', 'synthetic-psk', 20001))
        self.assertEqual(p.parse_go_handover(b'0200000000013&2412').port, 8959)
        self.assertNotIn('synthetic-psk', repr(info))
        for raw in [b'0200000000013&2412&a&short', b'0200000000013&2412&a&synthetic&0',
                    b'0200000000013&-1', b'020000000001&2412']:
            with self.assertRaises(p.ProtocolError): p.parse_go_handover(raw)

    def test_approval_metadata_has_no_account_or_false_acceptance(self):
        raw = p.encode_approval_metadata('anDrop Probe')
        parts = raw.decode().split('&')
        self.assertEqual(parts[1:], ['1', '11', 'anDrop Probe', '', '', '', 'text/plain', '', '0', ''])
        self.assertEqual(int(parts[0]), p.java_length(raw.decode()))
        japanese = p.encode_approval_metadata('合成😀')
        self.assertEqual(int(japanese.split(b'&')[0]), p.java_length(japanese.decode()))
        for name in ['wrong&field', 'line\nbreak', '']:
            with self.assertRaises(p.ProtocolError): p.encode_approval_metadata(name)
        self.assertEqual(p.decode_approval_result(base64.b64encode(b'ok')), 'ok')
        self.assertEqual(p.decode_approval_result(b'b2s=\n'), 'ok')
        self.assertEqual(p.decode_approval_result(base64.b64encode(b'no')), 'no')
        with self.assertRaises(p.ProtocolError): p.decode_approval_result(b'ok')

    def test_phone_sender_wps_fields_and_complete_length(self):
        body = '0200000000013&2412&11&020000000002&DIRECT-Synthetic&synthetic-psk&null'
        raw = p._length_prefix(body)
        info = p.parse_start_wps(raw)
        self.assertEqual((info.mac_or_ciphertext, info.bluetooth_mac, info.ssid_or_ciphertext, info.port),
                         ('020000000001', '020000000002', 'DIRECT-Synthetic', 8959))
        dynamic = p.parse_start_wps(p._length_prefix(body + '&20001&true&0'))
        self.assertEqual(dynamic.port, 20001)
        self.assertNotIn('synthetic-psk', repr(info))
        for raw in [raw[:-1], b'1&' + body.encode(), p._length_prefix(body + '&0&true&0')]:
            with self.assertRaises(p.ProtocolError): p.parse_start_wps(raw)

    def test_six_source_derived_frame_vectors_fragmented(self):
        fixtures = [(0, '', 1), (1, p.ARG_SEPARATOR.join(['1', 'Synthetic', '12', 'anDrop Probe', 'text/plain']), 0),
                    (2, 'text/plain', 0), (10, '合成テキスト😀', 0),
                    (10, 'https://example.invalid/synthetic', 0), (5, '1&&_&&text/plain&&_&&synthetic', 0)]
        wire = b''.join(p.encode_command(*row) for row in fixtures)
        decoder = p.CommandDecoder()
        result = []
        for offset in range(0, len(wire), 3): result += decoder.feed(wire[offset:offset + 3])
        decoder.finish()
        self.assertEqual([(item.command, item.text, item.flag) for item in result], fixtures)
        expected = bytes.fromhex('000003e900001000000000000000000c000000000000000000000001')
        self.assertEqual(p.encode_command(0, '', 1), expected)

    def test_hostile_frames_fail_before_body_allocation(self):
        for header in [struct.pack('>iiq', 1001, 4096, 65537), struct.pack('>iiq', 1001, 4096, -1),
                       struct.pack('>iiq', 1001, 8192, 12), struct.pack('>iiq', 0, 4096, 12)]:
            with self.assertRaises(p.ProtocolError): p.CommandDecoder().feed(header)
        wire = p.encode_command(10, 'a')
        for payload in [wire[:24] + b'\xff' + wire[25:], wire[:-4] + struct.pack('>i', 2),
                        wire[:20] + struct.pack('>i', 9) + wire[24:]]:
            with self.assertRaises(p.ProtocolError): p.CommandDecoder().feed(payload)
        decoder = p.CommandDecoder()
        decoder.feed(wire[:-1])
        with self.assertRaises(p.ProtocolError): decoder.finish()

    def test_ecdh_and_native_ctr_use_raw_32_bytes(self):
        try:
            import cryptography
        except ImportError:
            self.skipTest('cryptography unavailable in this interpreter')
        private_a, public_a = p.native_keypair()
        private_b, public_b = p.native_keypair()
        secret_a = p.native_shared_secret(private_a, public_b)
        secret_b = p.native_shared_secret(private_b, public_a)
        self.assertEqual(secret_a, secret_b)
        self.assertEqual(len(secret_a), 32)
        for value in ['DIRECT-Synthetic', 'synthetic-psk', '合成😀']:
            encrypted = p.native_ctr(value, secret_a)
            self.assertEqual(p.native_ctr(encrypted, secret_b, decrypt=True), value)
        with self.assertRaises(p.ProtocolError): p.native_shared_secret(private_a, 'not DER')
        with self.assertRaises(p.ProtocolError): p.native_ctr('%%', secret_a, decrypt=True)


if __name__ == '__main__':
    unittest.main()
