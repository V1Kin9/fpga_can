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
  tb_sniffer_top
  tb_can_rx_top
)

for top in "${tops[@]}"; do
  echo "=== $top ==="
  iverilog -g2012 -s "$top" -o "$BUILD/$top.vvp" "$ROOT"/rtl/*.v "$ROOT"/tb/*.sv
  output="$(vvp "$BUILD/$top.vvp")"
  printf '%s\n' "$output"
  grep -q '^\[PASS\]' <<<"$output"
done

echo "[PASS] All ${#tops[@]} CAN simulation tops"
