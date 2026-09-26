# Ethernet / IPv4 / UDP frame layer

This layer wraps the verified FCAN UDP payload in Ethernet II, IPv4 and UDP headers without depending on the physical FPGA board.

## Layer boundary

`can_udp_ipv4_eth_pipeline_top` produces a MAC-client frame stream:

```text
Destination MAC
Source MAC
EtherType 0x0800
IPv4 header
UDP header
FCAN UDP payload
```

It intentionally does **not** generate:

- Ethernet preamble
- SFD
- minimum-frame padding
- Ethernet FCS/CRC32
- inter-frame gap
- RGMII DDR signaling
- PHY reset / MDIO configuration

Those functions belong to the MAC/RGMII/RTL8211E integration layer.

The FCAN payload is always large enough that Ethernet minimum payload padding is not currently required: one FCAN record produces a 68-byte IPv4 packet.

## Default network identity

Defaults are compile-time parameters and can be changed when the actual PC/network setup is known.

| Field | Default |
| --- | --- |
| FPGA source MAC | `02:00:00:00:00:01` |
| PC destination MAC | `02:00:00:00:00:02` |
| FPGA source IPv4 | `192.168.50.2` |
| PC destination IPv4 | `192.168.50.1` |
| UDP source port | `5000` |
| UDP destination port | `5000` |
| IPv4 TTL | `64` |

The destination MAC is static in this phase. ARP is therefore not implemented yet.

## IPv4

The generated IPv4 header uses:

- version 4, IHL 5
- no IP options
- Don't Fragment flag
- protocol 17 (UDP)
- identification = low 16 bits of the FCAN datagram sequence
- a calculated IPv4 header checksum
- static source/destination IPv4 addresses

## UDP

The UDP length is calculated as `8 + FCAN payload length`.

The UDP checksum is set to zero. A zero UDP checksum is valid for IPv4 and keeps this hardware-independent stage small. A later revision may add the optional UDP checksum if required.

## Ready/valid contract

Before a frame starts:

- upstream asserts `packet_valid`, payload length and sequence
- downstream asserts `frame_ready`
- the frame builder acknowledges with `packet_ready`

After that handshake, Ethernet/IP/UDP header bytes are emitted first. The FCAN packetizer is backpressured until the builder enters the payload state.

The byte stream uses:

- `tx_valid`
- `tx_ready`
- `tx_data[7:0]`
- `tx_last`

Header and payload bytes remain stable while `tx_valid=1` and `tx_ready=0`.

## Verification

The regression suite checks:

1. exact Ethernet destination/source MAC bytes
2. EtherType 0x0800
3. IPv4 total length and identification
4. Don't Fragment, TTL and UDP protocol fields
5. exact IPv4 header checksum
6. UDP source/destination ports and length
7. zero UDP checksum
8. payload byte preservation under backpressure
9. full CAN waveform → CAN parser → FCAN → Ethernet/IPv4/UDP frame output

Physical Ethernet behavior remains unproven until the board and RTL8211E are available.
