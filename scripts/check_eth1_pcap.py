#!/usr/bin/env python3
"""Validate router-side classic pcap evidence from the isolated ETH1 bench."""

from __future__ import annotations

import argparse
import ipaddress
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "host"))
from can_udp_decode import decode_payload


def packets(path: Path):
    data = path.read_bytes()
    if len(data) < 24:
        raise ValueError("pcap global header is truncated")
    magic = data[:4]
    if magic == b"\xd4\xc3\xb2\xa1":
        byteorder, scale = "<", 1_000_000
    elif magic == b"\xa1\xb2\xc3\xd4":
        byteorder, scale = ">", 1_000_000
    elif magic == b"\x4d\x3c\xb2\xa1":
        byteorder, scale = "<", 1_000_000_000
    elif magic == b"\xa1\xb2\x3c\x4d":
        byteorder, scale = ">", 1_000_000_000
    else:
        raise ValueError("expected classic pcap")
    if struct.unpack_from(byteorder + "I", data, 20)[0] != 1:
        raise ValueError("expected Ethernet link type")
    offset = 24
    while offset < len(data):
        if offset + 16 > len(data):
            raise ValueError("truncated packet header")
        sec, frac, caplen, wirelen = struct.unpack_from(byteorder + "IIII", data, offset)
        offset += 16
        if caplen > wirelen or offset + caplen > len(data):
            raise ValueError("truncated packet bytes")
        yield sec + frac / scale, data[offset : offset + caplen]
        offset += caplen


def checksum16(data: bytes) -> int:
    if len(data) & 1:
        data += b"\x00"
    words = struct.unpack("!" + "H" * (len(data) // 2), data)
    value = sum(words)
    while value >> 16:
        value = (value & 0xFFFF) + (value >> 16)
    return value


def validate_fcan_sequences(decoded):
    """Require contiguous packets within each nonrepeating capture session."""
    previous = None
    seen_sessions = set()
    for packet in decoded:
        if previous is not None:
            if packet.session_id == previous.session_id:
                if packet.sequence != (previous.sequence + 1) & 0xFFFFFFFF:
                    raise ValueError("FCAN sequence skipped, repeated, or reordered")
            elif packet.session_id in seen_sessions:
                raise ValueError("FCAN session ID reappeared after a session change")
        # Captures may start mid-session, including after a session transition.
        seen_sessions.add(packet.session_id)
        previous = packet


def decode_udp(frame: bytes) -> bytes:
    if len(frame) < 42 or frame[:6] != bytes.fromhex("9483c42aeb74"):
        raise ValueError("unexpected destination MAC or short Ethernet frame")
    if frame[6:12] != bytes.fromhex("020000000001") or frame[12:14] != b"\x08\x00":
        raise ValueError("unexpected source MAC or EtherType")
    ip = frame[14:]
    ihl = (ip[0] & 0x0F) * 4
    if ip[0] >> 4 != 4 or ihl < 20 or len(ip) < ihl + 8:
        raise ValueError("invalid IPv4 header")
    if checksum16(ip[:ihl]) != 0xFFFF:
        raise ValueError("invalid IPv4 checksum")
    iplen = int.from_bytes(ip[2:4], "big")
    if ip[9] != 17 or iplen > len(ip) or iplen < ihl + 8:
        raise ValueError("invalid IPv4 protocol or length")
    if ip[12:16] != ipaddress.IPv4Address("192.168.8.250").packed or \
       ip[16:20] != ipaddress.IPv4Address("192.168.8.1").packed:
        raise ValueError("unexpected IP endpoints")
    udp = ip[ihl:iplen]
    if udp[:4] != struct.pack("!HH", 5000, 5000):
        raise ValueError("unexpected UDP ports")
    if int.from_bytes(udp[4:6], "big") != len(udp) or udp[6:8] != b"\x00\x00":
        raise ValueError("invalid UDP length or checksum policy")
    return udp[8:]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("fixed", "fcan"))
    parser.add_argument("pcap", type=Path)
    parser.add_argument("--can-id", type=lambda s: int(s, 0))
    parser.add_argument("--data", help="expected CAN data as contiguous hex")
    args = parser.parse_args()
    rows = [(stamp, decode_udp(frame)) for stamp, frame in packets(args.pcap)]
    if not rows:
        raise ValueError("pcap contains no matching packets")
    if args.mode == "fixed":
        if len(rows) < 2:
            raise ValueError("need at least two fixed probe packets")
        sequences = []
        for _, payload in rows:
            if len(payload) != 8 or payload[:4] != b"FPGA":
                raise ValueError("invalid fixed probe payload")
            sequences.append(int.from_bytes(payload[4:], "big"))
        if any(b != (a + 1) & 0xFFFFFFFF for a, b in zip(sequences, sequences[1:])):
            raise ValueError("fixed probe sequence skipped or repeated")
        intervals = [b[0] - a[0] for a, b in zip(rows, rows[1:])]
        if any(not 0.08 <= interval <= 0.12 for interval in intervals):
            raise ValueError("fixed probe interval outside 100 ms +/-20 ms")
        print(f"[PASS] fixed UDP: {len(rows)} packets; sequence {sequences[0]}..{sequences[-1]}; "
              f"mean interval {sum(intervals)/len(intervals):.6f}s")
    else:
        decoded = [decode_payload(payload) for _, payload in rows]
        if any(packet.version != 2 or packet.session_id != 0x20261003 for packet in decoded):
            raise ValueError("unexpected FCAN version or bench session ID")
        frames = [frame for packet in decoded for frame in packet.frames]
        statuses = [status for packet in decoded for status in packet.statuses]
        errors = [error for packet in decoded for error in packet.errors]
        validate_fcan_sequences(decoded)
        expected_data = bytes.fromhex(args.data) if args.data is not None else None
        print(f"FCAN v2 UDP: {len(rows)} packets; {len(frames)} CAN frames, "
              f"{len(statuses)} statuses, {len(errors)} parser errors")
        if statuses:
            latest = statuses[-1]
            print(f"  latest status: rx_frames_total={latest.rx_frames_total} "
                  f"crc_errors={latest.crc_errors} stuff_errors={latest.stuff_errors} "
                  f"form_errors={latest.form_errors} "
                  f"queue_drops={latest.queue_drop_count}")
        for error in errors[:10]:
            print(f"  CAN_ERROR code={error.error_code} tick={error.timestamp_ticks}")
        if (args.can_id is not None or expected_data is not None) and not any(
            frame.crc_ok and (args.can_id is None or frame.can_id == args.can_id) and
            (expected_data is None or frame.payload == expected_data)
            for frame in frames
        ):
            raise ValueError("expected CAN frame is absent")
        print("[PASS] FCAN v2 UDP validation")
        for frame in frames[:10]:
            print(f"  ID=0x{frame.can_id:x} DLC={frame.dlc} data={frame.payload.hex()} "
                  f"CRC_OK={frame.crc_ok} tick={frame.timestamp_ticks}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ValueError as exc:
        print(f"[FAIL] {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
