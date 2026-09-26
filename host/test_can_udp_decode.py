import unittest

from can_udp_decode import decode_payload, format_record


def build_payload() -> bytes:
    header = (
        b"FCAN"
        + bytes([1, 16, 24, 2])
        + (7).to_bytes(4, "big")
        + b"\x00\x00\x00\x00"
    )
    record0 = (
        (0x123).to_bytes(4, "big")
        + bytes([0x04, 8, 0, 0])
        + (0x0102030405060708).to_bytes(8, "big")
        + bytes.fromhex("11 22 33 44 55 66 77 88")
    )
    record1 = (
        (0x18DAF110).to_bytes(4, "big")
        + bytes([0x05, 2, 0, 0])
        + (0x1112131415161718).to_bytes(8, "big")
        + bytes.fromhex("AA BB 00 00 00 00 00 00")
    )
    return header + record0 + record1


class DecodeTest(unittest.TestCase):
    def test_decode_known_hdl_vector(self):
        packet = decode_payload(build_payload())
        self.assertEqual(packet.sequence, 7)
        self.assertEqual(len(packet.frames), 2)

        first = packet.frames[0]
        self.assertEqual(first.can_id, 0x123)
        self.assertFalse(first.ide)
        self.assertFalse(first.rtr)
        self.assertTrue(first.crc_ok)
        self.assertEqual(first.dlc, 8)
        self.assertEqual(first.timestamp_ticks, 0x0102030405060708)
        self.assertEqual(first.payload, bytes.fromhex("11 22 33 44 55 66 77 88"))

        second = packet.frames[1]
        self.assertEqual(second.can_id, 0x18DAF110)
        self.assertTrue(second.ide)
        self.assertEqual(second.dlc, 2)
        self.assertEqual(second.payload, bytes.fromhex("AA BB"))
        self.assertIn("18DAF110", format_record(packet.sequence, second))

    def test_reject_bad_length(self):
        with self.assertRaises(ValueError):
            decode_payload(build_payload()[:-1])

    def test_reject_reserved_id_bits(self):
        payload = bytearray(build_payload())
        payload[16] = 0x80
        with self.assertRaises(ValueError):
            decode_payload(bytes(payload))

    def test_raw_dlc_15_clamps_payload_to_eight_bytes(self):
        payload = bytearray(build_payload())
        payload[21] = 15
        packet = decode_payload(bytes(payload))
        self.assertEqual(packet.frames[0].dlc, 15)
        self.assertEqual(len(packet.frames[0].payload), 8)


if __name__ == "__main__":
    unittest.main()
