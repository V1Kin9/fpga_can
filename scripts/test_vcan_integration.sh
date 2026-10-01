#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$(uname -s)" != Linux ]] || ! command -v ip >/dev/null ||
   ! python3 -c 'import socket; assert hasattr(socket, "PF_CAN")' 2>/dev/null; then
  echo '[SKIP] Linux iproute2 and Python SocketCAN are required'
  exit 0
fi

interface="vcanfcan$$"
if (( ${#interface} > 15 )); then
  echo '[SKIP] generated vcan interface name exceeds Linux limit'
  exit 0
fi
command -v modprobe >/dev/null && modprobe vcan 2>/dev/null || true
if ! ip link add "$interface" type vcan 2>/dev/null; then
  echo '[SKIP] CAP_NET_ADMIN or vcan module unavailable'
  exit 0
fi
trap 'ip link del "$interface" 2>/dev/null || true' EXIT
ip link set "$interface" up

python3 - "$ROOT" "$interface" <<'PY'
import socket
import struct
import subprocess
import sys
import time

root, interface = sys.argv[1:]
receiver = socket.socket(socket.PF_CAN, socket.SOCK_RAW, socket.CAN_RAW)
receiver.bind((interface,))
receiver.settimeout(4)
bridge = subprocess.Popen([sys.executable, f"{root}/host/fcan_socketcan_bridge.py",
                           "--bind", "127.0.0.1", "--port", "15001",
                           "--interface", interface], stdout=subprocess.DEVNULL,
                          stderr=subprocess.PIPE)
try:
    record = bytes((0, 4, 2, 0)) + (0x321).to_bytes(4, "big") + (123).to_bytes(8, "big")
    record += b"\x12\x34" + bytes(6) + bytes(8)
    payload = b"FCAN" + bytes((2, 20, 32, 1)) + bytes(4) + (1).to_bytes(4, "big")
    payload += bytes(4) + record
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp:
        for _ in range(4):
            udp.sendto(payload, ("127.0.0.1", 15001))
            try:
                data = receiver.recv(16)
                break
            except socket.timeout:
                if bridge.poll() is not None:
                    raise RuntimeError("bridge exited before forwarding")
        else:
            raise RuntimeError("no SocketCAN frame received")
    assert len(data) == 16, data
    assert struct.unpack_from("=I", data)[0] == 0x321, data
    assert data[4] == 2 and data[8:10] == b"\x12\x34", data
    print("[PASS] FCAN v2 UDP to real vcan SocketCAN frame")
finally:
    bridge.terminate()
    try:
        bridge.wait(timeout=3)
    except subprocess.TimeoutExpired:
        bridge.kill()
        bridge.wait()
    receiver.close()
PY
