import io
import struct
import unittest

from can_udp_decode import decode_payload
from fcan_capture import Capture, PcapngWriter, candump_line
from fcan_socketcan_bridge import Bridge


def v2_packet(sequence, session, *records):
    return (b"FCAN" + bytes((2, 20, 32, len(records))) +
            sequence.to_bytes(4, "big") + session.to_bytes(4, "big") + bytes(4) +
            b"".join(records))


def frame_record(can_id=0x123, flags=4, dlc=8, tick=100, data=b"\x01\x02\x03\x04\x05\x06\x07\x08"):
    return (bytes((0, flags, dlc, 0)) + can_id.to_bytes(4, "big") +
            tick.to_bytes(8, "big") + data + bytes(8))


def error_record(code=2, tick=121):
    return bytes((1, code, 0, 0)) + bytes(4) + tick.to_bytes(8, "big") + bytes(16)


def status_record():
    return bytes((2, 1, 4, 12)) + bytes(4) + (1000).to_bytes(8, "big") + b"".join(
        n.to_bytes(2, "big") for n in range(1, 9))


def blocks(data):
    result = []
    offset = 0
    while offset < len(data):
        kind, length = struct.unpack_from("<II", data, offset)
        assert struct.unpack_from("<I", data, offset + length - 4)[0] == length
        result.append((kind, data[offset + 8:offset + length - 4]))
        offset += length
    assert offset == len(data)
    return result


class FakeSink:
    def __init__(self):
        self.sent = []

    def send(self, frame):
        self.sent.append(frame)


class V2Test(unittest.TestCase):
    def test_decode_types_and_v1_compatibility(self):
        packet = decode_payload(v2_packet(9, 0x12345678, frame_record(dlc=15),
                                          error_record(), status_record()))
        self.assertEqual((packet.version, packet.session_id, packet.sequence), (2, 0x12345678, 9))
        self.assertEqual(packet.frames[0].payload, bytes(range(1, 9)))
        self.assertEqual(packet.frames[0].dlc, 15)
        self.assertEqual(packet.errors[0].error_code, 2)
        self.assertEqual(packet.statuses[0].mac_underrun_count, 7)
        self.assertEqual(packet.statuses[0].diagnostic_drop_count, 8)

    def test_reject_reserved_and_unknown(self):
        bad = bytearray(v2_packet(0, 1, frame_record()))
        bad[16] = 1
        with self.assertRaises(ValueError):
            decode_payload(bytes(bad))
        bad = bytearray(v2_packet(0, 1, frame_record()))
        bad[20] = 99
        with self.assertRaises(ValueError):
            decode_payload(bytes(bad))

    def test_session_transition_after_lost_first_packet(self):
        sink = FakeSink()
        bridge = Bridge(sink)
        self.assertEqual(bridge.process_datagram(v2_packet(77, 1, frame_record())), 1)
        self.assertEqual(bridge.process_datagram(v2_packet(1, 2, frame_record())), 1)
        self.assertEqual(bridge.reset_epochs, 1)
        self.assertEqual(len(sink.sent), 2)
        self.assertEqual(bridge.process_datagram(v2_packet(1, 2, frame_record())), 0)

    def test_pcapng_socketcan_and_fpga_time(self):
        output = io.BytesIO()
        log = io.StringIO()
        capture = Capture(PcapngWriter(output), log)
        extended = frame_record(0x18DAF110, 0x05, 9, 100, b"ABCDEFGH")
        remote = frame_record(0x321, 0x06, 4, 150)
        self.assertEqual(capture.process_datagram(v2_packet(0, 7, extended, remote), 1_000_000_000), 2)
        entries = blocks(output.getvalue())
        self.assertEqual([b[0] for b in entries], [0x0A0D0D0A, 1, 6, 6])
        self.assertEqual(struct.unpack_from("<H", entries[1][1])[0], 227)
        self.assertEqual(entries[1][1][-12:],
                         b"\x09\x00\x01\x00\x09\x00\x00\x00"
                         b"\x00\x00\x00\x00")
        frame_a = entries[2][1][20:36]
        frame_b = entries[3][1][20:36]
        self.assertEqual(struct.unpack_from(">I", frame_a)[0], 0x98DAF110)
        self.assertEqual(frame_a[4], 8)
        self.assertEqual(frame_a[7], 9)
        self.assertEqual(frame_a[8:16], b"ABCDEFGH")
        self.assertEqual(struct.unpack_from(">I", frame_b)[0], 0x40000321)
        self.assertEqual(frame_b[4], 4)
        self.assertEqual(frame_b[7], 0)
        self.assertEqual(frame_b[8:16], bytes(8))
        self.assertEqual(entries[2][1][-4:], bytes(4))
        self.assertEqual(entries[3][1][-4:], bytes(4))
        timestamp_a = struct.unpack_from("<IIIII", entries[2][1])[1:3]
        timestamp_b = struct.unpack_from("<IIIII", entries[3][1])[1:3]
        self.assertEqual((timestamp_b[0] << 32 | timestamp_b[1]) -
                         (timestamp_a[0] << 32 | timestamp_a[1]), 1000)
        self.assertIn("fpga_sof_ticks=100;host_arrival_ns=1000000000", entries[2][1].decode("ascii", "ignore"))
        self.assertIn("18DAF110#4142434445464748_9", log.getvalue())
        self.assertIn("321#R4", log.getvalue())

    def test_candump_relative_timestamp(self):
        record = decode_payload(v2_packet(0, 1, frame_record(tick=50_000_000))).frames[0]
        self.assertEqual(candump_line(record), "(1.000000) can0 123#0102030405060708")

    def test_capture_reports_diagnostics_and_skips_bad_crc(self):
        output = io.BytesIO()
        log = io.StringIO()
        capture = Capture(PcapngWriter(output), log)
        self.assertEqual(capture.process_datagram(v2_packet(0, 1, error_record(),
                          status_record(), frame_record(flags=0)), 1_000_000_000), 0)
        self.assertEqual([kind for kind, _ in blocks(output.getvalue())], [0x0A0D0D0A, 1])
        self.assertIn("# CAN_ERROR code=2", log.getvalue())
        self.assertIn("# DEVICE_STATUS frames=1", log.getvalue())
        self.assertIn("# CAN_FRAME CRC_OK=0", log.getvalue())


if __name__ == "__main__":
    unittest.main()
