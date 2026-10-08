import hashlib
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import check_eth1_pcap


BENCH_SESSION = 0x20261003
EXPECTED_DATA = bytes.fromhex("a5")


def frame_record(*, crc_ok=True, can_id=0x123, data=EXPECTED_DATA):
    return (bytes((0, 4 if crc_ok else 0, len(data), 0)) +
            can_id.to_bytes(4, "big") + bytes(8) + data.ljust(8, b"\x00") + bytes(8))


def fcan_payload(sequence, *records, session=BENCH_SESSION):
    return (b"FCAN" + bytes((2, 20, 32, len(records))) +
            struct.pack("!II", sequence, session) + bytes(4) + b"".join(records))


def ethernet_frame(payload):
    udp = struct.pack("!HHHH", 5000, 5000, 8 + len(payload), 0) + payload
    ip = bytearray(struct.pack("!BBHHHBBH4s4s", 0x45, 0, 20 + len(udp), 0, 0,
                               64, 17, 0, bytes((192, 168, 8, 250)), bytes((192, 168, 8, 1))))
    struct.pack_into("!H", ip, 10, 0xFFFF ^ check_eth1_pcap.checksum16(ip))
    return bytes.fromhex("9483c42aeb740200000000010800") + ip + udp


def write_pcap(path, payloads):
    data = bytearray(struct.pack("<IHHIIII", 0xA1B2C3D4, 2, 4, 0, 0, 65535, 1))
    for index, payload in enumerate(payloads):
        frame = ethernet_frame(payload)
        data.extend(struct.pack("<IIII", 1 + index, 0, len(frame), len(frame)))
        data.extend(frame)
    path.write_bytes(data)


class PcapIntegrityTest(unittest.TestCase):
    def run_checker(self, path, *options, mode="fcan"):
        return subprocess.run(
            [sys.executable, str(ROOT / "scripts" / "check_eth1_pcap.py"), mode,
             str(path), *options], capture_output=True, text=True, check=False)

    def check_payloads(self, payloads, *options):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "capture.pcap"
            write_pcap(path, payloads)
            return self.run_checker(path, *options)

    def assert_passes(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("[PASS]", result.stdout)

    def assert_fails(self, result, message):
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn(message, result.stderr)
        self.assertNotIn("[PASS]", result.stdout)

    def test_consecutive_sequences_need_not_start_at_zero(self):
        self.assert_passes(self.check_payloads(
            [fcan_payload(sequence, frame_record()) for sequence in (37, 38, 39)],
            "--can-id", "0x123", "--data", "a5"))

    def test_sequence_wraparound(self):
        self.assert_passes(self.check_payloads(
            [fcan_payload(sequence, frame_record()) for sequence in (0xFFFFFFFE, 0xFFFFFFFF, 0, 1)]))

    def test_sequence_drop(self):
        self.assert_fails(self.check_payloads(
            [fcan_payload(sequence, frame_record()) for sequence in (10, 12)]),
            "FCAN sequence")

    def test_sequence_duplicate(self):
        self.assert_fails(self.check_payloads(
            [fcan_payload(sequence, frame_record()) for sequence in (10, 10)]),
            "FCAN sequence")

    def test_sequence_reorder(self):
        self.assert_fails(self.check_payloads(
            [fcan_payload(sequence, frame_record()) for sequence in (10, 11, 9)]),
            "FCAN sequence")

    def test_sequence_drop_at_wraparound(self):
        self.assert_fails(self.check_payloads(
            [fcan_payload(sequence, frame_record()) for sequence in (0xFFFFFFFF, 1)]),
            "FCAN sequence")

    def test_continuity_includes_status_and_error_packets(self):
        records = (frame_record(), bytes((2,)) + bytes(31), bytes((1, 2)) + bytes(30))
        self.assert_passes(self.check_payloads(
            [fcan_payload(sequence, record) for sequence, record in zip((10, 11, 12), records)]))
        self.assert_fails(self.check_payloads(
            [fcan_payload(sequence, record) for sequence, record in zip((10, 12, 13), records)]),
            "FCAN sequence")

    def test_crc_bad_match_does_not_satisfy_expected_frame(self):
        for options in (("--can-id", "0x123"), ("--can-id", "0x123", "--data", "a5")):
            with self.subTest(options=options):
                self.assert_fails(self.check_payloads(
                    [fcan_payload(10, frame_record(crc_ok=False))], *options),
                    "expected CAN frame is absent")

    def test_valid_match_can_follow_crc_bad_match(self):
        self.assert_passes(self.check_payloads(
            [fcan_payload(10, frame_record(crc_ok=False)), fcan_payload(11, frame_record())],
            "--can-id", "0x123", "--data", "a5"))

    def test_unrelated_valid_frame_does_not_rescue_crc_bad_match(self):
        for record in (frame_record(can_id=0x124), frame_record(data=b"\xa6")):
            with self.subTest(record=record):
                self.assert_fails(self.check_payloads(
                    [fcan_payload(10, frame_record(crc_ok=False), record)],
                    "--can-id", "0x123", "--data", "a5"),
                    "expected CAN frame is absent")

    def test_crc_bad_frames_remain_available_as_diagnostics(self):
        result = self.check_payloads([fcan_payload(10, frame_record(crc_ok=False))])
        self.assert_passes(result)
        self.assertIn("CRC_OK=False", result.stdout)

    def test_data_only_requires_a_matching_crc_valid_frame(self):
        self.assert_passes(self.check_payloads(
            [fcan_payload(10, frame_record(can_id=0x456))], "--data", "a5"))
        for record in (frame_record(data=b"\xa6"), frame_record(crc_ok=False),
                       bytes((2,)) + bytes(31), bytes((1, 2)) + bytes(30)):
            with self.subTest(record=record):
                self.assert_fails(self.check_payloads(
                    [fcan_payload(10, record)], "--data", "a5"),
                    "expected CAN frame is absent")

    def test_explicit_empty_data_asserts_zero_length_payload(self):
        self.assert_passes(self.check_payloads(
            [fcan_payload(10, frame_record(data=b""))], "--data", ""))
        self.assert_fails(self.check_payloads(
            [fcan_payload(10, frame_record())], "--data", ""),
            "expected CAN frame is absent")

    def test_session_sequences_start_independently(self):
        packets = [check_eth1_pcap.decode_payload(fcan_payload(sequence, session=session))
                   for session, sequence in ((1, 77), (1, 78), (2, 5), (2, 6))]
        check_eth1_pcap.validate_fcan_sequences(packets)

    def test_sequence_drop_in_new_session(self):
        packets = [check_eth1_pcap.decode_payload(fcan_payload(sequence, session=session))
                   for session, sequence in ((1, 77), (2, 5), (2, 7))]
        with self.assertRaisesRegex(ValueError, "FCAN sequence"):
            check_eth1_pcap.validate_fcan_sequences(packets)

    def test_old_session_replay_is_rejected(self):
        packets = [check_eth1_pcap.decode_payload(fcan_payload(sequence, session=session))
                   for session, sequence in ((1, 77), (2, 5), (1, 78))]
        with self.assertRaisesRegex(ValueError, "FCAN session"):
            check_eth1_pcap.validate_fcan_sequences(packets)

    def test_archived_captures(self):
        evidence = ROOT / "docs" / "evidence" / "eth1_udp_20261003"
        captures = sorted(evidence.glob("*.pcap"))
        self.assertEqual(len(captures), 8)
        for path in captures:
            with self.subTest(capture=path.name):
                mode = "fixed" if path.name.startswith("fixed_udp") else "fcan"
                options = ("--can-id", "0x123", "--data", "a5") if "burst24" in path.name else ()
                self.assert_passes(self.run_checker(path, *options, mode=mode))
        self.assert_fails(self.run_checker(evidence / "can_no_ack.pcap",
                                          "--can-id", "0x123", "--data", "a5"),
                          "expected CAN frame is absent")
        self.assert_fails(self.run_checker(evidence / "can_no_ack.pcap", "--data", "deadbeef"),
                          "expected CAN frame is absent")

    def test_archived_csv_checksum_line_endings_are_documented(self):
        evidence = ROOT / "docs" / "evidence" / "eth1_udp_20261003"
        # Git stores LF; a checkout configured for CRLF may expose that variant.
        # Normalize only in memory and verify both documented byte digests.
        data = (evidence / "can_ack_delimiter_error.csv").read_bytes().replace(b"\r\n", b"\n")
        lf_digest = hashlib.sha256(data).hexdigest()
        crlf_digest = hashlib.sha256(data.replace(b"\n", b"\r\n")).hexdigest()
        self.assertEqual(lf_digest, "b23dca55f79b54417662569364679aeca26840e5edab1d87a4de2944a4c733ca")
        self.assertEqual(crlf_digest, "47df71ab5b1b2e17cc259cc7c5d459fc3291cafdb1fd5995598e36bba0f66165")
        documentation = (ROOT / "docs" / "eth1_udp_board_bringup.md").read_text(encoding="utf-8")
        self.assertIn(lf_digest, documentation)
        self.assertIn(crlf_digest, documentation)


if __name__ == "__main__":
    unittest.main()
