#!/usr/bin/env python3
"""Decode the FPGA FCAN UDP payload format."""

from __future__ import annotations

import argparse
import socket
from dataclasses import dataclass
from typing import List, Tuple

MAGIC = b"FCAN"
VERSION = 1  # Kept as the v1 compatibility constant.
HEADER_LEN = 16
RECORD_LEN = 24
V2_HEADER_LEN = 20
V2_RECORD_LEN = 32


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
class CanErrorRecord:
    error_code: int
    subtype: int
    auxiliary: int
    timestamp_ticks: int


@dataclass(frozen=True)
class DeviceStatusRecord:
    flags: int
    queue_level: int
    queue_high_watermark: int
    uptime_ticks: int
    rx_frames_total: int
    crc_errors: int
    stuff_errors: int
    form_errors: int
    queue_drop_count: int
    cdc_protocol_error_count: int
    mac_underrun_count: int
    diagnostic_drop_count: int


@dataclass(frozen=True)
class CanPacket:
    sequence: int
    frames: Tuple[CanRecord, ...]
    version: int = 1
    session_id: int | None = None
    errors: Tuple[CanErrorRecord, ...] = ()
    statuses: Tuple[DeviceStatusRecord, ...] = ()
    records: Tuple[CanRecord | CanErrorRecord | DeviceStatusRecord, ...] = ()


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

    if version not in (1, 2):
        raise ValueError(f"unsupported FCAN version {version}")
    expected_header_len = HEADER_LEN if version == 1 else V2_HEADER_LEN
    expected_record_len = RECORD_LEN if version == 1 else V2_RECORD_LEN
    if header_len != expected_header_len:
        raise ValueError(f"unsupported FCAN header length {header_len}")
    if record_len != expected_record_len:
        raise ValueError(f"unsupported FCAN record length {record_len}")
    if len(payload) < header_len:
        raise ValueError("payload shorter than FCAN header")
    if version == 1:
        if payload[12:16] != bytes(4):
            raise ValueError("FCAN v1 header reserved bytes are non-zero")
        session_id = None
    else:
        session_id = int.from_bytes(payload[12:16], "big")
        if payload[16:20] != bytes(4):
            raise ValueError("FCAN v2 header reserved bytes are non-zero")

    expected = header_len + frame_count * record_len
    if len(payload) != expected:
        raise ValueError(
            f"FCAN payload length {len(payload)} does not match header {expected}"
        )

    frames: List[CanRecord] = []
    errors: List[CanErrorRecord] = []
    statuses: List[DeviceStatusRecord] = []
    records: List[CanRecord | CanErrorRecord | DeviceStatusRecord] = []
    offset = header_len
    for _ in range(frame_count):
        record = payload[offset : offset + record_len]
        if version == 2 and record[0] == 1:
            if record[3] or record[16:32] != bytes(16):
                raise ValueError("CAN_ERROR reserved bytes are non-zero")
            error = CanErrorRecord(record[1], record[2],
                int.from_bytes(record[4:8], "big"), int.from_bytes(record[8:16], "big"))
            errors.append(error)
            records.append(error)
            offset += record_len
            continue
        if version == 2 and record[0] == 2:
            if record[1] & 0xF8:
                raise ValueError("DEVICE_STATUS reserved flag bits are non-zero")
            if record[4:8] != bytes(4):
                raise ValueError("DEVICE_STATUS reserved bytes are non-zero")
            counters = tuple(int.from_bytes(record[i:i+2], "big") for i in range(16, 32, 2))
            status = DeviceStatusRecord(record[1], record[2], record[3],
                int.from_bytes(record[8:16], "big"), *counters)
            statuses.append(status)
            records.append(status)
            offset += record_len
            continue
        if version == 2 and record[0] != 0:
            raise ValueError(f"unsupported FCAN v2 record type {record[0]}")
        raw_id = int.from_bytes(record[4:8] if version == 2 else record[0:4], "big")
        if raw_id & ~0x1FFFFFFF:
            raise ValueError(f"CAN ID has reserved high bits set: 0x{raw_id:08x}")

        flags = record[1] if version == 2 else record[4]
        if flags & 0xF8:
            raise ValueError(f"record has reserved flag bits set: 0x{flags:02x}")
        if not (flags & 0x01) and raw_id > 0x7FF:
            raise ValueError(f"standard CAN ID exceeds 11 bits: 0x{raw_id:08x}")

        dlc = record[2] if version == 2 else record[5]
        if dlc > 15:
            raise ValueError(f"invalid Classical CAN DLC {dlc}")
        if (record[3] if version == 2 else record[6:8]) != (0 if version == 2 else b"\x00\x00"):
            raise ValueError("record reserved bytes are non-zero")
        if version == 2 and record[24:32] != bytes(8):
            raise ValueError("CAN_FRAME trailing reserved bytes are non-zero")

        frame = CanRecord(
                can_id=raw_id,
                ide=bool(flags & 0x01),
                rtr=bool(flags & 0x02),
                crc_ok=bool(flags & 0x04),
                dlc=dlc,
                timestamp_ticks=int.from_bytes(record[8:16], "big"),
                data=bytes(record[16:24]),
            )
        frames.append(frame)
        records.append(frame)
        offset += record_len

    return CanPacket(sequence=sequence, frames=tuple(frames), version=version,
                     session_id=session_id, errors=tuple(errors), statuses=tuple(statuses),
                     records=tuple(records))


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
        for error in packet.errors:
            print(f"seq={packet.sequence} CAN_ERROR code={error.error_code} ts={error.timestamp_ticks}")
        for status in packet.statuses:
            print(f"seq={packet.sequence} DEVICE_STATUS frames={status.rx_frames_total} drops={status.queue_drop_count}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bind", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=5000)
    args = parser.parse_args()
    listen(args.bind, args.port)


if __name__ == "__main__":
    main()
