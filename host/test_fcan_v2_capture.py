import io
import struct
import unittest

from can_udp_decode import decode_payload
from fcan_capture import Capture, PcapngWriter, candump_line
from fcan_socketcan_bridge import Bridge


def v1_packet(sequence, tick):
    return (b"FCAN" + bytes((1, 16, 24, 1)) + sequence.to_bytes(4, "big") + bytes(4) +
            (0x123).to_bytes(4, "big") + bytes((4, 8, 0, 0)) + tick.to_bytes(8, "big") +
            bytes(range(1, 9)))


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


def pcap_timestamps(output):
    return [(struct.unpack_from("<I", body, 4)[0] << 32) |
            struct.unpack_from("<I", body, 8)[0]
            for kind, body in blocks(output.getvalue()) if kind == 6]


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

    def test_capture_reordered_and_duplicate_packets_do_not_reanchor(self):
        output = io.BytesIO()
        log = io.StringIO()
        capture = Capture(PcapngWriter(output), log)
        arrival = 1_700_000_000_000_000_000
        self.assertEqual(capture.process_datagram(
            v2_packet(10, 7, frame_record(tick=1000)), arrival), 1)
        self.assertEqual(capture.process_datagram(
            v2_packet(12, 7, frame_record(tick=3000)), arrival + 10_000_000), 1)
        state = (capture.version, capture.session_id, capture.previous_sequence,
                 capture.epoch_offset_ns, capture.last_tick)
        for sequence, tick in ((11, 2000), (12, 3000), (0, 0)):
            with self.subTest(sequence=sequence):
                self.assertEqual(capture.process_datagram(
                    v2_packet(sequence, 7, frame_record(tick=tick)), arrival + 20_000_000), 0)
                self.assertEqual((capture.version, capture.session_id, capture.previous_sequence,
                                  capture.epoch_offset_ns, capture.last_tick), state)
        self.assertEqual(capture.process_datagram(
            v2_packet(13, 7, frame_record(tick=4000)), arrival + 30_000_000), 1)
        self.assertEqual(pcap_timestamps(output), [arrival, arrival + 40_000, arrival + 60_000])
        self.assertEqual(sum(line.startswith("(") for line in log.getvalue().splitlines()), 3)
        self.assertIn("duplicate/reordered", log.getvalue())

    def test_capture_sequence_wrap_preserves_epoch(self):
        output = io.BytesIO()
        capture = Capture(PcapngWriter(output), None)
        arrival = 1_700_000_000_000_000_000
        for index, sequence in enumerate((0xFFFFFFFE, 0xFFFFFFFF, 0, 1)):
            self.assertEqual(capture.process_datagram(
                v2_packet(sequence, 7, frame_record(tick=100 + index * 100)),
                arrival + index * 1_000_000), 1)
        self.assertEqual(pcap_timestamps(output),
                         [arrival, arrival + 2000, arrival + 4000, arrival + 6000])
        self.assertEqual(capture.previous_sequence, 1)
        self.assertEqual(capture.epoch_offset_ns, arrival - 2000)

    def test_capture_new_session_reanchors_without_sequence_zero(self):
        for new_sequence in (1, 100):
            with self.subTest(new_sequence=new_sequence):
                output = io.BytesIO()
                capture = Capture(PcapngWriter(output), None)
                arrival = 1_700_000_000_000_000_000
                self.assertEqual(capture.process_datagram(
                    v2_packet(77, 1, frame_record(tick=50_000)), arrival), 1)
                self.assertEqual(capture.process_datagram(
                    v2_packet(new_sequence, 2, frame_record(tick=100)), arrival + 2_000_000), 1)
                for old_sequence in (78, 0):
                    self.assertEqual(capture.process_datagram(
                        v2_packet(old_sequence, 1, frame_record(tick=60_000)),
                        arrival + 4_000_000), 0)
                    self.assertEqual((capture.version, capture.session_id, capture.previous_sequence,
                                      capture.epoch_offset_ns, capture.last_tick),
                                     (2, 2, new_sequence, arrival + 1_998_000, 100))
                self.assertEqual(capture.process_datagram(
                    v2_packet(new_sequence + 1, 2, frame_record(tick=150)),
                    arrival + 6_000_000), 1)
                self.assertEqual(pcap_timestamps(output),
                                 [arrival, arrival + 2_000_000, arrival + 2_001_000])
                self.assertEqual(list(capture.retired_sessions), [1])

    def test_capture_new_session_diagnostics_wait_for_first_frame_anchor(self):
        output = io.BytesIO()
        capture = Capture(PcapngWriter(output), None)
        arrival = 1_700_000_000_000_000_000
        capture.process_datagram(v2_packet(77, 1, frame_record(tick=50_000)), arrival)
        self.assertEqual(capture.process_datagram(
            v2_packet(1, 2, error_record(), status_record()), arrival + 1_000_000), 0)
        self.assertEqual((capture.session_id, capture.previous_sequence), (2, 1))
        self.assertIsNone(capture.epoch_offset_ns)
        self.assertIsNone(capture.last_tick)
        self.assertEqual(capture.process_datagram(
            v2_packet(2, 2, frame_record(tick=100)), arrival + 5_000_000), 1)
        self.assertEqual(pcap_timestamps(output), [arrival, arrival + 5_000_000])

    def test_capture_in_order_backward_ticks_do_not_reanchor(self):
        output = io.BytesIO()
        log = io.StringIO()
        capture = Capture(PcapngWriter(output), log)
        arrival = 1_700_000_000_000_000_000
        capture.process_datagram(v2_packet(0, 7, frame_record(tick=1000)), arrival)
        self.assertEqual(capture.process_datagram(
            v2_packet(1, 7, frame_record(tick=900)), arrival + 1_000_000), 0)
        self.assertEqual((capture.previous_sequence, capture.epoch_offset_ns, capture.last_tick),
                         (1, arrival - 20_000, 1000))
        self.assertEqual(capture.process_datagram(
            v2_packet(2, 7, frame_record(tick=1100), frame_record(tick=1000),
                      frame_record(tick=1200)), arrival + 2_000_000), 2)
        self.assertEqual(capture.process_datagram(
            v2_packet(3, 7, frame_record(tick=1300)), arrival + 3_000_000), 1)
        self.assertEqual(pcap_timestamps(output),
                         [arrival, arrival + 2000, arrival + 4000, arrival + 6000])
        self.assertEqual(capture.last_tick, 1300)
        self.assertEqual(capture.epoch_offset_ns, arrival - 20_000)
        self.assertEqual(log.getvalue().count("FPGA timestamp moved backward"), 2)

    def test_capture_empty_or_invalid_packets_do_not_retire_session(self):
        output = io.BytesIO()
        capture = Capture(PcapngWriter(output), None)
        arrival = 1_700_000_000_000_000_000
        capture.process_datagram(v2_packet(10, 1, frame_record(tick=100)), arrival)
        for payload in (v2_packet(0, 2), b"invalid"):
            self.assertEqual(capture.process_datagram(payload, arrival + 1_000_000), 0)
            self.assertEqual((capture.version, capture.session_id, capture.previous_sequence,
                              capture.epoch_offset_ns, capture.last_tick),
                             (2, 1, 10, arrival - 2000, 100))
            self.assertEqual(list(capture.retired_sessions), [])
        self.assertEqual(capture.process_datagram(
            v2_packet(11, 1, frame_record(tick=200)), arrival + 2_000_000), 1)
        self.assertEqual(pcap_timestamps(output), [arrival, arrival + 2000])

    def test_capture_retired_session_history_is_bounded(self):
        output = io.BytesIO()
        capture = Capture(PcapngWriter(output), None, max_retired_sessions=3)
        for session in range(1, 6):
            self.assertEqual(capture.process_datagram(
                v2_packet(1, session, frame_record()), session * 1_000_000_000), 1)
        self.assertEqual(list(capture.retired_sessions), [2, 3, 4])
        self.assertEqual(capture.retired_history_evictions, 1)
        self.assertEqual(capture.process_datagram(v2_packet(2, 4, frame_record()), 9_000_000_000), 0)
        self.assertEqual((capture.session_id, capture.previous_sequence, capture.epoch_offset_ns),
                         (5, 1, 4_999_998_000))
        self.assertEqual(list(capture.retired_sessions), [2, 3, 4])
        self.assertEqual(pcap_timestamps(output), [n * 1_000_000_000 for n in range(1, 6)])

    def test_capture_retired_session_limit_must_be_positive(self):
        for limit in (0, -1):
            with self.subTest(limit=limit), self.assertRaises(ValueError):
                Capture(None, None, max_retired_sessions=limit)

    def test_capture_v1_restart_and_backward_tick_compatibility(self):
        output = io.BytesIO()
        capture = Capture(PcapngWriter(output), None)
        arrival = 1_700_000_000_000_000_000
        self.assertEqual(capture.process_datagram(v1_packet(10, 1000), arrival), 1)
        self.assertEqual(capture.process_datagram(v1_packet(0, 100), arrival + 1_000_000), 1)
        self.assertEqual(capture.process_datagram(v1_packet(0, 50), arrival + 2_000_000), 0)
        self.assertEqual(capture.process_datagram(v1_packet(1, 200), arrival + 3_000_000), 1)
        # Accepted in-order v1 ticks can still establish a new clock epoch.
        self.assertEqual(capture.process_datagram(v1_packet(2, 10), arrival + 4_000_000), 1)
        self.assertEqual(capture.process_datagram(v1_packet(3, 60), arrival + 5_000_000), 1)
        self.assertEqual(pcap_timestamps(output),
                         [arrival, arrival + 1_000_000, arrival + 1_002_000,
                          arrival + 4_000_000, arrival + 4_001_000])

    def test_capture_v1_reordering_cannot_trigger_backward_tick_fallback(self):
        output = io.BytesIO()
        capture = Capture(PcapngWriter(output), None)
        arrival = 1_700_000_000_000_000_000
        capture.process_datagram(v1_packet(10, 1000), arrival)
        capture.process_datagram(v1_packet(12, 3000), arrival + 1_000_000)
        self.assertEqual(capture.process_datagram(v1_packet(11, 2000), arrival + 2_000_000), 0)
        self.assertEqual((capture.previous_sequence, capture.epoch_offset_ns, capture.last_tick),
                         (12, arrival - 20_000, 3000))
        self.assertEqual(capture.process_datagram(v1_packet(13, 4000), arrival + 3_000_000), 1)
        self.assertEqual(pcap_timestamps(output), [arrival, arrival + 40_000, arrival + 60_000])

    def test_capture_version_change_retires_previous_v2_session(self):
        output = io.BytesIO()
        capture = Capture(PcapngWriter(output), None)
        arrival = 1_700_000_000_000_000_000
        capture.process_datagram(v2_packet(77, 0, frame_record(tick=1000)), arrival)
        self.assertEqual(capture.process_datagram(v1_packet(1, 100), arrival + 1_000_000), 1)
        self.assertEqual(capture.process_datagram(
            v2_packet(78, 0, frame_record(tick=2000)), arrival + 2_000_000), 0)
        self.assertEqual((capture.version, capture.session_id, capture.previous_sequence,
                          capture.epoch_offset_ns, capture.last_tick),
                         (1, None, 1, arrival + 998_000, 100))
        self.assertEqual(capture.process_datagram(v1_packet(2, 150), arrival + 3_000_000), 1)
        self.assertEqual(capture.process_datagram(
            v2_packet(10, 1, frame_record(tick=10)), arrival + 4_000_000), 1)
        self.assertEqual(pcap_timestamps(output),
                         [arrival, arrival + 1_000_000, arrival + 1_001_000, arrival + 4_000_000])
        self.assertEqual(list(capture.retired_sessions), [0])

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
