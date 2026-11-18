"""Exercise the host wire format against an independent device-side exchange."""
import hashlib
import hmac
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "macos"))
import cli


class PairingTests(unittest.TestCase):
    def test_ephemeral_key_wrap_and_host_binding(self):
        key = bytes(range(32))
        device = ec.generate_private_key(ec.SECP256R1())
        public = device.public_key().public_bytes(serialization.Encoding.X962,
                                                  serialization.PublicFormat.UncompressedPoint)
        wrap = None

        def exchange(port, command, **options):
            nonlocal wrap
            verb, action, value = command.split()
            self.assertEqual((port, verb), ("usb", "PAIR"))
            packet = bytes.fromhex(value)
            if action == "OPEN":
                peer = ec.EllipticCurvePublicKey.from_encoded_point(device.curve, packet)
                shared = device.exchange(ec.ECDH(), peer)
                wrap = hashlib.sha256(b"tinyTouch host pairing v1" + packet + public + shared).digest()
                return ["OK PAIR OPEN " + public.hex()]
            self.assertEqual(action, "FINISH")
            self.assertNotIn(key, packet)
            self.assertEqual(packet[:8].hex(), cli.host_id(key))
            self.assertEqual(AESGCM(wrap).decrypt(packet[8:20], packet[20:], packet[:8]), key)
            return ["OK PAIR FINISH " + hmac.digest(key, packet, "sha256").hex()]

        with patch.object(cli, "serial_command", side_effect=exchange) as transport:
            cli.add_wrapped_host("usb", key)
        self.assertEqual(transport.call_count, 2)

    def test_public_key_without_registration_receipt_is_rejected(self):
        device = ec.generate_private_key(ec.SECP256R1())
        point = device.public_key().public_bytes(serialization.Encoding.X962,
                                                 serialization.PublicFormat.UncompressedPoint)
        replies = [["OK PAIR OPEN " + point.hex()], ["OK PAIR FINISH " + "0" * 64]]
        with patch.object(cli, "serial_command", side_effect=replies):
            with self.assertRaisesRegex(cli.ToolError, "confirm"):
                cli.add_wrapped_host("usb", bytes(32))

    def test_malformed_peer_stops_before_sending_key(self):
        with patch.object(cli, "serial_command", return_value=["OK PAIR OPEN 00"]) as transport:
            with self.assertRaises(cli.ToolError):
                cli.add_wrapped_host("usb", bytes(32))
            transport.assert_called_once()
