"""Session validation in the router capture checker, without network access."""

import importlib.util
from contextlib import redirect_stderr, redirect_stdout
from io import StringIO
from pathlib import Path
import unittest
from unittest.mock import patch

from test_fcan_v2_capture import frame_record, v1_packet, v2_packet

spec = importlib.util.spec_from_file_location(
    "check_eth1_pcap", Path(__file__).resolve().parents[1] / "scripts/check_eth1_pcap.py")
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


class PcapSessionTest(unittest.TestCase):
    def check(self, payloads, *options):
        # Isolate session policy from the already-existing Ethernet parser.
        with patch.object(checker, "packets", return_value=enumerate(payloads)), \
                patch.object(checker, "decode_udp", side_effect=lambda frame: frame), \
                redirect_stdout(StringIO()), redirect_stderr(StringIO()):
            return checker.main(["fcan", "unused.pcap", *options])

    def test_link_recovery_sessions_and_lost_zero_are_valid(self):
        self.assertEqual(self.check([
            v2_packet(100, 0x20261003, frame_record()),
            v2_packet(1, 0x20261004, frame_record()),
            v2_packet(2, 0x20261004, frame_record())]), 0)

    def test_custom_seed_is_valid(self):
        self.assertEqual(self.check([v2_packet(0, 7, frame_record())]), 0)

    def test_explicit_archived_session_is_checked(self):
        old = v2_packet(100, 0x20261003, frame_record())
        new = v2_packet(1, 0x20261004, frame_record())
        self.assertEqual(self.check([old], "--session-id", "0x20261003"), 0)
        with self.assertRaisesRegex(ValueError, "unexpected FCAN session ID"):
            self.check([old, new], "--session-id", "0x20261003")

    def test_v1_is_still_rejected(self):
        with self.assertRaisesRegex(ValueError, "unexpected FCAN version"):
            self.check([v1_packet(0, 100)])

    def test_expected_session_must_fit_wire_field(self):
        for value in ("-1", "0x100000000"):
            with self.subTest(value=value), self.assertRaises(SystemExit) as exc:
                self.check([], "--session-id", value)
            self.assertEqual(exc.exception.code, 2)


if __name__ == "__main__":
    unittest.main()
