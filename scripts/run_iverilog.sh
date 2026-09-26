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
  tb_sniffer_top
  tb_can_rx_top
)

for top in "${tops[@]}"; do
  echo "=== $top ==="
  iverilog -g2012 -s "$top" -o "$BUILD/$top.vvp" "$ROOT"/rtl/*.v "$ROOT"/tb/*.sv
  log="$BUILD/$top.log"
  set +e
  vvp "$BUILD/$top.vvp" | tee "$log"
  rc=${PIPESTATUS[0]}
  set -e
  if [[ $rc -ne 0 ]]; then
    exit "$rc"
  fi
  grep -q '^\[PASS\]' "$log"
done

echo "[PASS] All ${#tops[@]} CAN simulation tops"
