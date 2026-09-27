"""SocketCAN conversion tests that need neither Linux nor a vcan device."""

import sys
import unittest

from fcan_socketcan_bridge import Bridge, CAN_EFF_FLAG, CAN_RTR_FLAG


class FakeCanSink:
    def __init__(self):
        self.frames = []

    def send(self, frame):
        self.frames.append(frame)


def fcan_record(can_id=0x321, *, ide=False, rtr=False, dlc=8,
                data=bytes.fromhex("11 22 33 44 55 66 77 88"),
                timestamp=0x0102030405060708, crc_ok=True):
    flags = int(ide) | (int(rtr) << 1) | (int(crc_ok) << 2)
    return (
        can_id.to_bytes(4, "big")
        + bytes([flags, dlc, 0, 0])
        + timestamp.to_bytes(8, "big")
        + data.ljust(8, b"\x00")
    )


def fcan_packet(sequence, *records):
    return (
        b"FCAN" + bytes([1, 16, 24, len(records)])
        + sequence.to_bytes(4, "big") + bytes(4)
        + b"".join(records)
    )


def fcan_v2_record(can_id=0x321, *, ide=False, rtr=False, dlc=8,
                   data=bytes.fromhex("11 22 33 44 55 66 77 88"),
                   timestamp=0x0102030405060708, crc_ok=True):
    flags = int(ide) | (int(rtr) << 1) | (int(crc_ok) << 2)
    return (
        bytes([0, flags, dlc, 0])
        + can_id.to_bytes(4, "big")
        + timestamp.to_bytes(8, "big")
        + data.ljust(8, b"\x00")
        + bytes(8)
    )


def fcan_v2_packet(sequence, session, *records):
    return (
        b"FCAN" + bytes([2, 20, 32, len(records)])
        + sequence.to_bytes(4, "big")
        + session.to_bytes(4, "big")
        + bytes(4)
        + b"".join(records)
    )


def unpack_frame(frame):
    assert len(frame) == 16
    return int.from_bytes(frame[:4], sys.byteorder), frame[4], frame[5:8], frame[8:16]


class BridgeTest(unittest.TestCase):
    def setUp(self):
        self.sink = FakeCanSink()
        self.bridge = Bridge(self.sink)

    def send(self, sequence=0, *records):
        return self.bridge.process_datagram(fcan_packet(sequence, *records))

    def test_standard_frame_exact_abi(self):
        self.assertEqual(self.send(3, fcan_record()), 1)
        self.assertEqual(unpack_frame(self.sink.frames[0]),
                         (0x321, 8, bytes(3), bytes.fromhex("11 22 33 44 55 66 77 88")))

    def test_extended_id_flag(self):
        self.send(0, fcan_record(0x18DAF110, ide=True, dlc=2, data=b"\xAA\xBB"))
        self.assertEqual(unpack_frame(self.sink.frames[0]),
                         (CAN_EFF_FLAG | 0x18DAF110, 2, bytes(3), b"\xAA\xBB" + bytes(6)))

    def test_remote_request_length_and_empty_data(self):
        self.send(0, fcan_record(0x123, rtr=True, dlc=5))
        self.assertEqual(unpack_frame(self.sink.frames[0]),
                         (CAN_RTR_FLAG | 0x123, 5, bytes(3), bytes(8)))

    def test_zero_dlc(self):
        self.send(0, fcan_record(dlc=0))
        self.assertEqual(unpack_frame(self.sink.frames[0])[1:], (0, bytes(3), bytes(8)))

    def test_dlc_eight(self):
        self.send(0, fcan_record(dlc=8))
        self.assertEqual(unpack_frame(self.sink.frames[0])[1], 8)

    def test_raw_dlc_nine_through_fifteen_clamps_length_and_preserves_data(self):
        for dlc in range(9, 16):
            with self.subTest(raw_dlc=dlc):
                self.send(dlc - 9, fcan_record(dlc=dlc))
                self.assertEqual(unpack_frame(self.sink.frames[-1]),
                                 (0x321, 8, bytes(3), bytes.fromhex("11 22 33 44 55 66 77 88")))

    def test_multiple_records_keep_packet_order(self):
        self.assertEqual(self.send(0, fcan_record(0x100), fcan_record(0x101)), 2)
        self.assertEqual([unpack_frame(frame)[0] for frame in self.sink.frames], [0x100, 0x101])

    def test_normal_sequence(self):
        self.send(10, fcan_record(0x100))
        self.send(11, fcan_record(0x101))
        self.assertEqual(self.bridge.previous_seq, 11)
        self.assertEqual(self.bridge.missing_packets, 0)
        self.assertEqual(len(self.sink.frames), 2)

    def test_sequence_loss_is_reported(self):
        self.send(10, fcan_record())
        with self.assertLogs("fcan_socketcan_bridge", level="WARNING") as logs:
            self.send(13, fcan_record())
        self.assertIn("missing=2", logs.output[0])
        self.assertEqual(self.bridge.missing_packets, 2)
        self.assertEqual(len(self.sink.frames), 2)

    def test_sequence_wraparound(self):
        self.send(0xFFFFFFFF, fcan_record(0x100))
        self.send(0, fcan_record(0x101))
        self.assertEqual(self.bridge.missing_packets, 0)
        self.assertEqual(self.bridge.reset_epochs, 0)
        self.assertEqual(self.bridge.previous_seq, 0)
        self.assertEqual(len(self.sink.frames), 2)

    def test_fpga_sequence_restart_accepts_new_epoch(self):
        self.send(100, fcan_record(0x100))
        with self.assertLogs("fcan_socketcan_bridge", level="WARNING") as logs:
            self.send(0, fcan_record(0x101))
        self.send(1, fcan_record(0x102))
        self.assertIn("restarted at zero", logs.output[0])
        self.assertEqual(self.bridge.reset_epochs, 1)
        self.assertEqual(self.bridge.missing_packets, 0)
        self.assertEqual([unpack_frame(frame)[0] for frame in self.sink.frames],
                         [0x100, 0x101, 0x102])

    def test_duplicate_zero_does_not_start_another_epoch(self):
        self.send(0, fcan_record(0x100))
        with self.assertLogs("fcan_socketcan_bridge", level="WARNING"):
            self.send(0, fcan_record(0x101))
        self.assertEqual(self.bridge.reset_epochs, 0)
        self.assertEqual(self.bridge.old_packets, 1)
        self.assertEqual(len(self.sink.frames), 1)

    def test_v2_same_session_sequence_restart_is_accepted(self):
        self.assertEqual(self.bridge.process_datagram(
            fcan_v2_packet(100, 7, fcan_v2_record(0x100))), 1)
        with self.assertLogs("fcan_socketcan_bridge", level="WARNING") as logs:
            self.assertEqual(self.bridge.process_datagram(
                fcan_v2_packet(0, 7, fcan_v2_record(0x101))), 1)
        self.assertEqual(self.bridge.process_datagram(
            fcan_v2_packet(1, 7, fcan_v2_record(0x102))), 1)
        self.assertIn("restarted at zero", "\n".join(logs.output))
        self.assertEqual(self.bridge.reset_epochs, 1)
        self.assertEqual([unpack_frame(frame)[0] for frame in self.sink.frames],
                         [0x100, 0x101, 0x102])

    def test_v2_retired_session_packets_are_dropped_without_state_change(self):
        self.assertEqual(self.bridge.process_datagram(
            fcan_v2_packet(77, 1, fcan_v2_record(0x100))), 1)
        self.assertEqual(self.bridge.process_datagram(
            fcan_v2_packet(1, 2, fcan_v2_record(0x101))), 1)
        with self.assertLogs("fcan_socketcan_bridge", level="WARNING") as logs:
            self.assertEqual(self.bridge.process_datagram(
                fcan_v2_packet(78, 1, fcan_v2_record(0x102))), 0)
        self.assertIn("stale FCAN session packet", "\n".join(logs.output))
        self.assertEqual(self.bridge.previous_session, 2)
        self.assertEqual(self.bridge.previous_seq, 1)
        self.assertEqual(self.bridge.stale_session_packets, 1)
        self.assertEqual(self.bridge.old_packets, 1)
        self.assertEqual(self.bridge.process_datagram(
            fcan_v2_packet(2, 2, fcan_v2_record(0x103))), 1)
        self.assertEqual([unpack_frame(frame)[0] for frame in self.sink.frames],
                         [0x100, 0x101, 0x103])

    def test_duplicate_and_reordered_datagrams_are_dropped(self):
        self.send(20, fcan_record(0x100))
        with self.assertLogs("fcan_socketcan_bridge", level="WARNING"):
            self.send(20, fcan_record(0x101))
            self.send(19, fcan_record(0x102))
        self.assertEqual([unpack_frame(frame)[0] for frame in self.sink.frames], [0x100])
        self.assertEqual(self.bridge.old_packets, 2)
        self.assertEqual(self.bridge.previous_seq, 20)

    def test_invalid_fcan_packet_is_dropped(self):
        with self.assertLogs("fcan_socketcan_bridge", level="WARNING"):
            self.assertEqual(self.bridge.process_datagram(b"NOT-FCAN"), 0)
        self.assertEqual(self.bridge.invalid_packets, 1)
        self.assertEqual(self.sink.frames, [])

    def test_reserved_header_bytes_are_rejected(self):
        payload = bytearray(fcan_packet(0, fcan_record()))
        payload[12] = 1
        with self.assertLogs("fcan_socketcan_bridge", level="WARNING"):
            self.assertEqual(self.bridge.process_datagram(bytes(payload)), 0)
        self.assertEqual(self.bridge.invalid_packets, 1)
        self.assertEqual(self.sink.frames, [])

    def test_invalid_standard_id_drops_whole_datagram(self):
        with self.assertLogs("fcan_socketcan_bridge", level="WARNING"):
            self.assertEqual(self.send(0, fcan_record(0x100), fcan_record(0x800)), 0)
        self.assertEqual(self.sink.frames, [])
        self.assertIsNone(self.bridge.previous_seq)

    def test_crc_bad_record_is_not_forwarded(self):
        with self.assertLogs("fcan_socketcan_bridge", level="WARNING"):
            self.assertEqual(self.send(0, fcan_record(crc_ok=False)), 0)
        self.assertEqual(self.sink.frames, [])

    def test_verbose_keeps_fpga_timestamp_and_raw_dlc_in_log(self):
        self.bridge.verbose = True
        with self.assertLogs("fcan_socketcan_bridge", level="INFO") as logs:
            self.send(7, fcan_record(dlc=15, timestamp=1234))
        self.assertIn("fpga_ts=1234", logs.output[0])
        self.assertIn("raw_dlc=15", logs.output[0])


if __name__ == "__main__":
    unittest.main()
