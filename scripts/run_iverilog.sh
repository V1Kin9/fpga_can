#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT

tops=(
  tb_bit_timing
  tb_bit_timing_resync
  tb_destuff
  tb_parser_standard
  tb_crc15
  tb_fifo_if
  tb_can_frame_queue
  tb_can_udp_payload_packetizer
  tb_can_udp_pipeline_top
  tb_udp_ipv4_eth_frame_builder
  tb_can_udp_ipv4_eth_pipeline_top
  tb_eth_frame_cdc_buffer
  tb_ethernet_mac_tx
  tb_sniffer_top
  tb_can_rx_top
  tb_can_gmii_pipeline_top
  tb_fcan_v2
  tb_can_udp_pipeline_v2
  tb_can_diagnostics
  tb_gray_event_counter_cdc
  tb_fcan_random_stress
  tb_can_reset_midframe
  tb_can_random_waveforms
  tb_mac_idle_reset
  tb_eth1_phy_probe
  tb_eth1_fixed_udp_sender
  tb_eth1_link_session
)

for top in "${tops[@]}"; do
  echo "=== $top ==="
  iverilog -g2012 -s "$top" -o "$BUILD/$top.vvp" "$ROOT"/rtl/*.v "$ROOT"/tb/*.sv
  log="$BUILD/$top.log"
  set +e
  if [[ "$top" == tb_fcan_random_stress ]]; then
    vvp "$BUILD/$top.vvp" "+SEED=${FCAN_STRESS_SEED:-1badb002}" \
        "+FRAMES=${FCAN_STRESS_FRAMES:-10000}" | tee "$log"
  else
    vvp "$BUILD/$top.vvp" | tee "$log"
  fi
  rc=${PIPESTATUS[0]}
  set -e
  if [[ $rc -ne 0 ]]; then
    exit "$rc"
  fi
  grep -q '^\[PASS\]' "$log"
done

for bitrate in 125000 250000 500000 1000000; do
  echo "=== CAN bitrate $bitrate ==="
  iverilog -g2012 -s tb_can_bitrate_matrix \
    -P "tb_can_bitrate_matrix.CAN_BITRATE=$bitrate" \
    -o "$BUILD/bitrate_$bitrate.vvp" "$ROOT"/rtl/*.v "$ROOT"/tb/*.sv
  vvp "$BUILD/bitrate_$bitrate.vvp" | tee "$BUILD/bitrate_$bitrate.log"
  grep -q "^\[PASS\] $bitrate$" "$BUILD/bitrate_$bitrate.log"
done

echo "[PASS] All ${#tops[@]} CAN simulation tops and four CAN bitrates"
