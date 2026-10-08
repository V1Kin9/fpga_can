#!/usr/bin/env python3
"""Forward FCAN UDP payloads to a Linux SocketCAN interface.

Linux's include/uapi/linux/can.h defines the 16-byte Classical can_frame ABI:
native-endian can_id (4), len (1), pad (1), res0 (1), len8_dlc (1), data (8).
"""

from __future__ import annotations

import argparse
import logging
import socket
import struct
import sys
from collections import OrderedDict
from ipaddress import IPv4Address
from typing import Protocol

from can_udp_decode import CanRecord, decode_payload

CAN_EFF_FLAG = 0x80000000
CAN_RTR_FLAG = 0x40000000
CAN_SFF_MASK = 0x000007FF
CAN_EFF_MASK = 0x1FFFFFFF
CAN_FRAME = struct.Struct("=IBBBB8s")
assert CAN_FRAME.size == 16

LOG = logging.getLogger("fcan_socketcan_bridge")
MAX_RETIRED_SESSIONS = 256


class CanSink(Protocol):
    def send(self, frame: bytes) -> None:
        """Write exactly one 16-byte Linux Classical CAN frame."""


class SocketCanSink:
    def __init__(self, interface: str) -> None:
        self.sock = socket.socket(socket.PF_CAN, socket.SOCK_RAW, socket.CAN_RAW)
        try:
            self.sock.bind((interface,))
        except BaseException:
            self.sock.close()
            raise

    def send(self, frame: bytes) -> None:
        sent = self.sock.send(frame)
        if sent != CAN_FRAME.size:
            raise OSError(f"short SocketCAN write: {sent}/{CAN_FRAME.size} bytes")

    def close(self) -> None:
        self.sock.close()

    def __enter__(self) -> SocketCanSink:
        return self

    def __exit__(self, _exc_type: object, _exc: object, _tb: object) -> None:
        self.close()


def pack_can_frame(record: CanRecord) -> bytes:
    """Pack the verified Linux can_frame ABI without inventing a kernel timestamp."""
    if not 0 <= record.dlc <= 15:
        raise ValueError(f"invalid Classical CAN DLC {record.dlc}")
    mask = CAN_EFF_MASK if record.ide else CAN_SFF_MASK
    if not 0 <= record.can_id <= mask:
        raise ValueError(f"CAN ID 0x{record.can_id:x} exceeds {'extended' if record.ide else 'standard'} range")

    can_id = record.can_id
    if record.ide:
        can_id |= CAN_EFF_FLAG
    if record.rtr:
        can_id |= CAN_RTR_FLAG

    # An RTR frame has a requested length but no payload. Classical raw DLC
    # 9..15 occupies eight bytes; len8_dlc is left at zero because vcan and
    # ordinary CAN interfaces need not preserve the optional controller mode.
    length = min(record.dlc, 8)
    if record.rtr:
        data = bytes(8)
    else:
        if len(record.data) < length:
            raise ValueError("FCAN record has fewer data bytes than its DLC")
        data = record.data[:length].ljust(8, b"\x00")
    return CAN_FRAME.pack(can_id, length, 0, 0, 0, data)


class Bridge:
    def __init__(self, sink: CanSink, *, verbose: bool = False,
                 expected_source_ip: str | None = None,
                 max_retired_sessions: int = MAX_RETIRED_SESSIONS) -> None:
        if max_retired_sessions < 1:
            raise ValueError("max_retired_sessions must be positive")
        self.sink = sink
        self.verbose = verbose
        self.expected_source_ip = expected_source_ip
        self.max_retired_sessions = max_retired_sessions
        self.previous_seq: int | None = None
        self.previous_session: int | None = None
        self.previous_version: int | None = None
        self.retired_sessions: OrderedDict[int, None] = OrderedDict()
        self.retired_history_evictions = 0
        self.foreign_packets = 0
        self.forwarded_frames = 0
        self.invalid_packets = 0
        self.missing_packets = 0
        self.old_packets = 0
        self.stale_session_packets = 0
        self.reset_epochs = 0

    def process_datagram(self, payload: bytes, *, source_ip: str | None = None) -> int:
        """Decode, check sequence, and forward one FCAN UDP datagram.

        Returns the number of CAN frames written. Duplicate and old datagrams
        are dropped so the SocketCAN stream remains in sequence order.
        """
        if self.expected_source_ip is not None and source_ip != self.expected_source_ip:
            self.foreign_packets += 1
            if self.foreign_packets == 1:
                LOG.warning("FCAN datagram from unexpected source %s; dropping", source_ip)
            return 0

        try:
            packet = decode_payload(payload)
            frames = [pack_can_frame(record) for record in packet.frames]
        except ValueError as exc:
            self.invalid_packets += 1
            LOG.warning("invalid FCAN packet: %s", exc)
            return 0

        # The FPGA packetizer never emits a header without records. In
        # particular, such a packet must not retire the active v2 session.
        if not packet.records:
            self.invalid_packets += 1
            LOG.warning("empty FCAN packet; dropping")
            return 0

        sequence = packet.sequence

        # Reject replay from the bounded recent-session history. Older epochs
        # cannot be distinguished indefinitely without an ordered boot epoch.
        if (packet.version == 2 and packet.session_id is not None and
                packet.session_id in self.retired_sessions and
                packet.session_id != self.previous_session):
            self.old_packets += 1
            self.stale_session_packets += 1
            LOG.warning("stale FCAN session packet: session=%u seq=%u; dropping",
                        packet.session_id, sequence)
            return 0

        changed = self.previous_version is not None and (
            packet.version != self.previous_version or
            (packet.version == 2 and packet.session_id != self.previous_session)
        )
        if changed:
            if self.previous_version == 2 and self.previous_session is not None:
                self.retired_sessions[self.previous_session] = None
                self.retired_sessions.move_to_end(self.previous_session)
                if len(self.retired_sessions) > self.max_retired_sessions:
                    self.retired_sessions.popitem(last=False)
                    self.retired_history_evictions += 1
                    if self.retired_history_evictions == 1:
                        LOG.warning("FCAN retired-session history is full; oldest epoch forgotten")
            self.reset_epochs += 1
            LOG.warning("FCAN session/version changed: v%s/%s -> v%s/%s",
                        self.previous_version, self.previous_session,
                        packet.version, packet.session_id)
            self.previous_seq = None
        if self.previous_seq is not None:
            expected = (self.previous_seq + 1) & 0xFFFFFFFF
            gap = (sequence - expected) & 0xFFFFFFFF
            if (packet.version == 1 and sequence == 0 and expected != 0
                    and self.previous_seq != 0):
                # Legacy v1 has no epoch field, so keep its ambiguous zero
                # fallback. In v2 only a changed session denotes a restart:
                # an old delayed zero must not rewind the active watermark.
                # Normal 0xffffffff -> 0 wrap is handled as an in-order packet.
                self.reset_epochs += 1
                LOG.warning("FCAN sequence restarted at zero after %u; accepting new epoch", self.previous_seq)
            elif gap >= 0x80000000:
                self.old_packets += 1
                LOG.warning("duplicate/reordered FCAN packet: got=%u expected=%u; dropping", sequence, expected)
                return 0
            elif gap:
                self.missing_packets += gap
                LOG.warning("FCAN sequence gap: got=%u expected=%u missing=%u", sequence, expected, gap)

        self.previous_seq = sequence
        self.previous_version = packet.version
        self.previous_session = packet.session_id
        for error in packet.errors:
            LOG.warning("FCAN CAN_ERROR seq=%u code=%u fpga_ts=%u", sequence,
                        error.error_code, error.timestamp_ticks)
        for status in packet.statuses:
            LOG.info("FCAN DEVICE_STATUS seq=%u frames=%u queue_drop=%u diagnostic_drop=%u",
                     sequence, status.rx_frames_total, status.queue_drop_count,
                     status.diagnostic_drop_count)
        for record, frame in zip(packet.frames, frames):
            if not record.crc_ok:
                LOG.warning("seq=%u CAN ID=0x%x has CRC_OK=0; not forwarding", sequence, record.can_id)
                continue
            self.sink.send(frame)
            self.forwarded_frames += 1
            if self.verbose:
                LOG.info(
                    "seq=%u fpga_ts=%u (20 ns ticks) id=0x%x ide=%u rtr=%u raw_dlc=%u data=%s",
                    sequence, record.timestamp_ticks, record.can_id,
                    record.ide, record.rtr, record.dlc, record.payload.hex(" "),
                )
        return sum(record.crc_ok for record in packet.frames)


def listen(bind: str, port: int, interface: str, *,
           expected_source_ip: str, verbose: bool = False) -> None:
    with SocketCanSink(interface) as sink, socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp:
        udp.bind((bind, port))
        bridge = Bridge(sink, verbose=verbose,
                        expected_source_ip=expected_source_ip)
        LOG.info("listening on %s:%u from %s; forwarding to %s",
                 bind, port, expected_source_ip, interface)
        try:
            while True:
                payload, source = udp.recvfrom(65535)
                LOG.debug("received %u bytes from %s:%u", len(payload), *source)
                bridge.process_datagram(payload, source_ip=source[0])
        except KeyboardInterrupt:
            LOG.info(
                "stopped: forwarded=%u invalid=%u foreign=%u missing=%u duplicate/reordered=%u stale_session=%u retired_evicted=%u resets=%u",
                bridge.forwarded_frames, bridge.invalid_packets,
                bridge.foreign_packets,
                bridge.missing_packets, bridge.old_packets,
                bridge.stale_session_packets, bridge.retired_history_evictions,
                bridge.reset_epochs,
            )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bind", default="127.0.0.1", help="local IPv4 listen address")
    parser.add_argument("--port", type=int, default=5000, help="UDP listen port (default: 5000)")
    parser.add_argument("--source-ip", help="expected FPGA source IPv4; required for non-loopback bind")
    parser.add_argument("--interface", default="vcan0", help="SocketCAN output interface")
    parser.add_argument("--verbose", action="store_true", help="log each FPGA timestamp and CAN record")
    args = parser.parse_args(argv)
    if not 1 <= args.port <= 65535:
        parser.error("--port must be between 1 and 65535")
    try:
        args.bind = str(IPv4Address(args.bind))
        if args.source_ip is not None:
            args.source_ip = str(IPv4Address(args.source_ip))
    except ValueError as exc:
        parser.error(str(exc))
    if args.source_ip is None:
        if args.bind != "127.0.0.1":
            parser.error("--source-ip is required when --bind is not 127.0.0.1")
        args.source_ip = "127.0.0.1"
    if sys.platform != "linux":
        parser.error("SocketCAN requires Linux; run this bridge on a Linux host")
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    try:
        listen(args.bind, args.port, args.interface,
               expected_source_ip=args.source_ip, verbose=args.verbose)
    except OSError as exc:
        LOG.error("SocketCAN/UDP I/O failed: %s", exc)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
