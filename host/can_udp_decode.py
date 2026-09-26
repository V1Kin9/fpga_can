#!/usr/bin/env python3
"""Decode the FPGA FCAN UDP payload format."""

from __future__ import annotations

import argparse
import socket
from dataclasses import dataclass
from typing import List, Tuple

MAGIC = b"FCAN"
VERSION = 1
HEADER_LEN = 16
RECORD_LEN = 24


@dataclass(frozen=True)
class CanRecord:
    can_id: int
    ide: bool
    rtr: bool
    crc_ok: bool
    dlc: int
    timestamp_ticks: int
    data: bytes

    @property
    def payload(self) -> bytes:
        if self.rtr:
            return b""
        return self.data[: min(self.dlc, 8)]


@dataclass(frozen=True)
class CanPacket:
    sequence: int
    frames: Tuple[CanRecord, ...]


def decode_payload(payload: bytes) -> CanPacket:
    if len(payload) < HEADER_LEN:
        raise ValueError("payload shorter than FCAN header")
    if payload[:4] != MAGIC:
        raise ValueError("invalid FCAN magic")

    version = payload[4]
    header_len = payload[5]
    record_len = payload[6]
    frame_count = payload[7]
    sequence = int.from_bytes(payload[8:12], "big")

    if version != VERSION:
        raise ValueError(f"unsupported FCAN version {version}")
    if header_len != HEADER_LEN:
        raise ValueError(f"unsupported FCAN header length {header_len}")
    if record_len != RECORD_LEN:
        raise ValueError(f"unsupported FCAN record length {record_len}")

    expected = header_len + frame_count * record_len
    if len(payload) != expected:
        raise ValueError(
            f"FCAN payload length {len(payload)} does not match header {expected}"
        )

    frames: List[CanRecord] = []
    offset = header_len
    for _ in range(frame_count):
        record = payload[offset : offset + record_len]
        raw_id = int.from_bytes(record[0:4], "big")
        if raw_id & ~0x1FFFFFFF:
            raise ValueError(f"CAN ID has reserved high bits set: 0x{raw_id:08x}")

        flags = record[4]
        if flags & 0xF8:
            raise ValueError(f"record has reserved flag bits set: 0x{flags:02x}")

        dlc = record[5]
        if dlc > 15:
            raise ValueError(f"invalid Classical CAN DLC {dlc}")
        if record[6:8] != b"\x00\x00":
            raise ValueError("record reserved bytes are non-zero")

        frames.append(
            CanRecord(
                can_id=raw_id,
                ide=bool(flags & 0x01),
                rtr=bool(flags & 0x02),
                crc_ok=bool(flags & 0x04),
                dlc=dlc,
                timestamp_ticks=int.from_bytes(record[8:16], "big"),
                data=bytes(record[16:24]),
            )
        )
        offset += record_len

    return CanPacket(sequence=sequence, frames=tuple(frames))


def format_record(sequence: int, frame: CanRecord) -> str:
    width = 8 if frame.ide else 3
    data = " ".join(f"{byte:02X}" for byte in frame.payload)
    kind = "RTR" if frame.rtr else "DATA"
    return (
        f"seq={sequence} ts={frame.timestamp_ticks} "
        f"id={frame.can_id:0{width}X} {kind} dlc={frame.dlc} "
        f"crc={'ok' if frame.crc_ok else 'bad'} data={data}"
    )


def listen(bind: str, port: int) -> None:
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind((bind, port))
    print(f"listening for FCAN UDP payloads on {bind}:{port}")
    while True:
        payload, source = sock.recvfrom(65535)
        try:
            packet = decode_payload(payload)
        except ValueError as exc:
            print(f"{source[0]}:{source[1]} invalid FCAN payload: {exc}")
            continue
        for frame in packet.frames:
            print(format_record(packet.sequence, frame))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bind", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=5000)
    args = parser.parse_args()
    listen(args.bind, args.port)


if __name__ == "__main__":
    main()
