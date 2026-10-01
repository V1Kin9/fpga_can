#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
SEED="${SEED:-1badb002}"
FRAME_COUNT="${FRAME_COUNT:-100000}"
if ! [[ "$SEED" =~ ^[0-9a-fA-F]+$ && "$FRAME_COUNT" =~ ^[0-9]+$ ]]; then
  echo 'SEED must be hex and FRAME_COUNT must be decimal' >&2
  exit 2
fi
iverilog -g2012 -s tb_fcan_random_stress -o "$BUILD/stress.vvp" \
  "$ROOT"/rtl/*.v "$ROOT"/tb/*.sv
vvp "$BUILD/stress.vvp" "+SEED=$SEED" "+FRAMES=$FRAME_COUNT"
