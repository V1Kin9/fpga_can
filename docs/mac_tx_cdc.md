# Ethernet MAC TX and clock-domain boundary

This stage bridges the verified 50 MHz CAN/network application pipeline into a 125 MHz GMII transmit domain without requiring the physical FPGA board.

## Architecture

```text
50 MHz application domain
CAN RX
  -> frame queue
  -> FCAN aggregation
  -> Ethernet II / IPv4 / UDP frame builder
  -> eth_frame_cdc_buffer
                         ||
                         || bundled-data toggle CDC
                         \/
125 MHz network domain
  -> ethernet_mac_tx
  -> GMII TXD[7:0] / TX_EN / TX_ER
  -> [future RGMII DDR + RTL8211E]
```

## Frame CDC buffer

`eth_frame_cdc_buffer` buffers one complete MAC-client frame before it becomes visible in the 125 MHz domain.

The producer:
1. handshakes frame length,
2. writes all frame bytes,
3. toggles a request only after the final byte is safely stored.

The consumer sees that request through a two-flop synchronizer, then reads a stable frame image. An acknowledgement toggle crosses back after the complete frame is consumed.

The multi-byte frame RAM and length use a bundled-data CDC contract: they are written before the synchronized request changes and remain stable until the synchronized acknowledgement returns.

Malformed source frames whose actual byte count does not match the announced length are dropped and raise `app_protocol_error`.

Default maximum MAC-client frame storage is 512 bytes. The current maximum FCAN Ethernet frame is below this limit.

## Ethernet MAC TX

`ethernet_mac_tx` accepts an already-buffered MAC-client frame and emits GMII bytes at one byte per network clock.

It generates:

- seven-byte preamble: `55 55 55 55 55 55 55`
- SFD: `D5`
- MAC-client frame bytes
- zero padding when the frame before FCS is shorter than 60 bytes
- IEEE 802.3 CRC32/FCS
- 12 byte-times of inter-frame gap

The CRC uses reflected polynomial `0xEDB88320`, initial value `0xFFFFFFFF`, final inversion, and transmits FCS least-significant byte first.

The MAC cannot pause an Ethernet frame after transmission starts. Therefore it is intended to consume only from the complete-frame CDC buffer. If its source ever fails to present a byte in the data state, `GMII_TX_ER` and `underrun_error` signal an invalid transmission.

## GMII boundary

`can_gmii_pipeline_top` exposes:

- `gmii_clk_125m` input
- `gmii_txd[7:0]`
- `gmii_tx_en`
- `gmii_tx_er`

No 125 MHz clock generation is implemented here. On the real Kintex7 Base board that clock and its RGMII phase relationship must be designed together with the RTL8211E interface.

## Remaining board-specific work

The remaining transmit path is intentionally limited to:

1. generate/route the required 125 MHz network clock,
2. convert GMII bytes/control to RGMII DDR,
3. apply the board/PHY-specific TX clock delay strategy,
4. reset/configure RTL8211E (including MDIO only where required),
5. constrain RGMII pins and source-synchronous timing,
6. verify physical packets on a PC/Wireshark.

Those items should be completed against the actual board revision and PHY behavior rather than guessed in a hardware-independent PR.
