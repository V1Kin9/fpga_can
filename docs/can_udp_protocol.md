# FCAN UDP payload protocol

This document defines the byte contract between the FPGA CAN capture pipeline and a future UDP/IP transmitter. The current RTL produces the **UDP payload only**; Ethernet, IPv4, UDP headers, RGMII timing and RTL8211E PHY bring-up are deliberately outside this layer.

All multi-byte integer fields use big-endian/network byte order. CAN data bytes preserve bus byte order: DATA0 is the first data byte.

## Datagram header

Each UDP payload begins with a 16-byte header.

| Offset | Size | Field | Definition |
| --- | ---: | --- | --- |
| 0 | 4 | magic | ASCII `FCAN` |
| 4 | 1 | version | `1` |
| 5 | 1 | header length | `16` |
| 6 | 1 | record length | `24` |
| 7 | 1 | frame count | number of records in this datagram |
| 8 | 4 | sequence | monotonically increasing datagram sequence |
| 12 | 4 | reserved | zero |

Default RTL aggregates at most 16 frames. A partially filled datagram is flushed after `FLUSH_CYCLES`; at 50 MHz the default 50,000 cycles is approximately 1 ms.

## CAN frame record

Each frame occupies 24 bytes.

| Offset | Size | Field | Definition |
| --- | ---: | --- | --- |
| 0 | 4 | CAN ID | low 29 bits valid, high 3 bits zero |
| 4 | 1 | flags | bit0 IDE, bit1 RTR, bit2 CRC_OK |
| 5 | 1 | raw DLC | Classical CAN DLC 0..15 |
| 6 | 2 | reserved | zero |
| 8 | 8 | timestamp | 50 MHz SOF timestamp ticks; 20 ns/tick |
| 16 | 8 | data | DATA0..DATA7 |

For Classical CAN raw DLC 9..15, all eight data bytes are present and the original DLC value is retained. For RTR frames the data bytes are ignored.

## RTL boundary

`can_udp_pipeline_top` implements:

```text
CAN RX
  -> passive CAN decoder
  -> one-frame skid buffer
  -> multi-frame queue
  -> FCAN payload aggregator
  -> packet request + byte stream
```

The output contract toward the future UDP/IP core is:

- `packet_valid / packet_ready`: one handshake per UDP datagram.
- `packet_length`: complete UDP payload length.
- `packet_sequence`: sequence encoded in the current payload.
- `tx_valid / tx_ready / tx_data / tx_last`: 8-bit payload stream with normal ready/valid backpressure.

The packetizer does not accept new frames while serializing a datagram. The upstream multi-frame queue absorbs this short interval. At 1 GbE the serialization time is tiny compared with a 500 kbit/s CAN frame interval.

## Host decoder

```bash
python host/can_udp_decode.py --bind 0.0.0.0 --port 5000
```

The host decoder validates magic, protocol version, lengths, reserved bits and payload size before returning records.

## Verification boundary

CI verifies queue ordering/backpressure, packet aggregation/timeout, wire format, host decoding, and CAN-waveform-to-FCAN end-to-end behavior. It does not prove Ethernet MAC, IPv4/UDP checksum, RGMII DDR timing, PHY reset/MDIO configuration, cabling or real vehicle behavior.
