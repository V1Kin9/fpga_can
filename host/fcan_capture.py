#!/usr/bin/env python3
"""Capture FCAN UDP as SocketCAN PCAPNG and/or can-utils compact log."""

from __future__ import annotations

import argparse
import logging
import socket
import struct
import time
from pathlib import Path
from typing import BinaryIO, TextIO

from can_udp_decode import CanErrorRecord, CanRecord, DeviceStatusRecord, decode_payload

LOG = logging.getLogger("fcan_capture")
LINKTYPE_CAN_SOCKETCAN = 227
CAN_EFF_FLAG = 0x80000000
CAN_RTR_FLAG = 0x40000000


def _option(code: int, value: bytes) -> bytes:
    return struct.pack("<HH", code, len(value)) + value + bytes((-len(value)) % 4)


def _block(kind: int, body: bytes) -> bytes:
    total = 12 + len(body)
    return struct.pack("<II", kind, total) + body + struct.pack("<I", total)


class PcapngWriter:
    """One nanosecond-resolution SocketCAN interface; EPB timestamps are UTC."""

    def __init__(self, stream: BinaryIO, interface: str = "can0") -> None:
        self.stream = stream
        # SHB: byte-order magic, version 1.0, unspecified section length.
        stream.write(_block(0x0A0D0D0A, struct.pack("<IHHq", 0x1A2B3C4D, 1, 0, -1)))
        # IDB: linktype 227, snaplen 16; if_name=2, if_tsresol=9 (10^-9 s).
        options = _option(2, interface.encode("utf-8")) + _option(9, b"\x09")
        stream.write(_block(1, struct.pack("<HHI", LINKTYPE_CAN_SOCKETCAN, 0, 16) + options))

    def write_frame(self, record: CanRecord, epoch_ns: int, host_arrival_ns: int,
                    session_id: int | None) -> None:
        can_id = record.can_id | (CAN_EFF_FLAG if record.ide else 0)
        can_id |= CAN_RTR_FLAG if record.rtr else 0
        dlc = min(record.dlc, 8)
        data = bytes(8) if record.rtr else record.payload.ljust(8, b"\x00")
        # LINKTYPE_CAN_SOCKETCAN stores CAN ID in network byte order, unlike
        # the native-endian Linux socket ABI used by fcan_socketcan_bridge.
        frame = struct.pack(">I", can_id) + bytes((dlc, 0, 0, 0)) + data
        comment = (f"fpga_sof_ticks={record.timestamp_ticks};host_arrival_ns={host_arrival_ns};"
                   f"session_id={session_id if session_id is not None else 'v1'}").encode("ascii")
        body = (struct.pack("<IIIII", 0, epoch_ns >> 32, epoch_ns & 0xFFFFFFFF, 16, 16)
                + frame + _option(1, comment))
        self.stream.write(_block(6, body))


def candump_line(record: CanRecord, interface: str = "can0") -> str:
    """can-utils compact format. Timestamp is FPGA uptime, not Unix time."""
    ns = record.timestamp_ticks * 20
    seconds, remainder = divmod(ns, 1_000_000_000)
    identifier = f"{record.can_id:08X}" if record.ide else f"{record.can_id:03X}"
    if record.rtr:
        body = f"R{min(record.dlc, 8)}"
    else:
        body = record.payload.hex().upper()
        if record.dlc > 8:
            body += f"_{record.dlc:X}"
    return f"({seconds}.{remainder // 1000:06d}) {interface} {identifier}#{body}"


class Capture:
    def __init__(self, pcap: PcapngWriter | None, log: TextIO | None,
                 interface: str = "can0") -> None:
        self.pcap = pcap
        self.log = log
        self.interface = interface
        self.session_id: int | None = None
        self.version: int | None = None
        self.epoch_offset_ns: int | None = None
        self.last_tick: int | None = None
        self.previous_sequence: int | None = None

    def _event(self, message: str) -> None:
        LOG.warning(message)
        if self.log:
            self.log.write("# " + message + "\n")

    def process_datagram(self, payload: bytes, host_arrival_ns: int | None = None) -> int:
        if host_arrival_ns is None:
            host_arrival_ns = time.time_ns()
        try:
            packet = decode_payload(payload)
        except ValueError as exc:
            self._event(f"invalid FCAN datagram: {exc}")
            return 0
        changed = self.version is not None and (packet.version != self.version or
                   (packet.version == 2 and packet.session_id != self.session_id))
        if changed:
            self._event(f"FCAN session changed: {self.session_id} -> {packet.session_id}")
            self.epoch_offset_ns = None
            self.last_tick = None
            self.previous_sequence = None
        if self.previous_sequence is not None:
            expected = (self.previous_sequence + 1) & 0xFFFFFFFF
            if packet.sequence != expected:
                self._event(f"FCAN sequence discontinuity: expected={expected} got={packet.sequence}")
        self.previous_sequence = packet.sequence
        self.session_id = packet.session_id
        self.version = packet.version
        written = 0
        for record in packet.records:
            if isinstance(record, CanErrorRecord):
                self._event(f"CAN_ERROR code={record.error_code} fpga_ticks={record.timestamp_ticks}")
                continue
            if isinstance(record, DeviceStatusRecord):
                self._event(f"DEVICE_STATUS frames={record.rx_frames_total} queue_drop={record.queue_drop_count} "
                            f"diagnostic_drop={record.diagnostic_drop_count}")
                continue
            frame = record
            if not frame.crc_ok:
                self._event(f"CAN_FRAME CRC_OK=0 id=0x{frame.can_id:x} fpga_ticks={frame.timestamp_ticks}; skipped")
                continue
            if self.last_tick is not None and frame.timestamp_ticks < self.last_tick:
                self._event("FPGA timestamp moved backward; starting new capture epoch")
                self.epoch_offset_ns = None
            self.last_tick = frame.timestamp_ticks
            if self.epoch_offset_ns is None:
                # Host arrival establishes only the Unix epoch anchor. All
                # subsequent inter-frame timing comes from FPGA SOF ticks.
                self.epoch_offset_ns = host_arrival_ns - frame.timestamp_ticks * 20
            if self.pcap:
                self.pcap.write_frame(frame, self.epoch_offset_ns + frame.timestamp_ticks * 20,
                                      host_arrival_ns, packet.session_id)
            if self.log:
                self.log.write(candump_line(frame, self.interface) + "\n")
            written += 1
        return written


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bind", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=5000)
    parser.add_argument("--pcap", type=Path, help="SocketCAN PCAPNG output")
    parser.add_argument("--log", type=Path, help="can-utils compact log output")
    parser.add_argument("--interface", default="can0", help="capture interface label")
    args = parser.parse_args(argv)
    if not args.pcap and not args.log:
        parser.error("specify --pcap and/or --log")
    if not 1 <= args.port <= 65535:
        parser.error("--port must be in 1..65535")
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp:
            udp.bind((args.bind, args.port))
            with (args.pcap.open("wb") if args.pcap else open_null_binary()) as pcap_file:
                with (args.log.open("w", encoding="utf-8", newline="\n")
                      if args.log else open_null_text()) as log_file:
                    capture = Capture(PcapngWriter(pcap_file, args.interface) if args.pcap else None,
                                      log_file if args.log else None, args.interface)
                    LOG.info("listening on %s:%u", args.bind, args.port)
                    while True:
                        data, _ = udp.recvfrom(65535)
                        capture.process_datagram(data)
    except KeyboardInterrupt:
        return 0
    except OSError as exc:
        LOG.error("capture I/O failed: %s", exc)
        return 1


def open_null_binary() -> BinaryIO:
    return open("NUL" if __import__("sys").platform == "win32" else "/dev/null", "wb")


def open_null_text() -> TextIO:
    return open("NUL" if __import__("sys").platform == "win32" else "/dev/null", "w")


if __name__ == "__main__":
    raise SystemExit(main())
