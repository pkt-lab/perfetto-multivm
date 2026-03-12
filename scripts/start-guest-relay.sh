#!/usr/bin/env bash
# start-guest-relay.sh
# Start Perfetto traced_relay + traced_probes on QEMU guest
# Run inside the guest (SSH or serial console)
#
# Usage: bash start-guest-relay.sh [TRACEBOX_PATH] [HOST_VSOCK_PORT]
#
# TRACEBOX_PATH:  path to tracebox binary (default: /tmp/tracebox54)
# HOST_VSOCK_PORT: vsock port the host traced is listening on (default: 20001)
#
# VMADDR_CID_HOST = 2 (always points to host from any guest)

set -euo pipefail

TRACEBOX="${1:-/tmp/tracebox54}"
HOST_PORT="${2:-20001}"
HOST_CID=2   # VMADDR_CID_HOST — always 2 from guest perspective
RELAY_SOCK="/tmp/perfetto-producer"
RELAY_LOG="/tmp/relay.log"
PROBES_LOG="/tmp/probes.log"

if [[ ! -x "$TRACEBOX" ]]; then
  echo "ERROR: $TRACEBOX not found or not executable"
  exit 1
fi

# Verify vsock device exists
if [[ ! -c /dev/vsock ]]; then
  echo "ERROR: /dev/vsock not found. Check QEMU -device vhost-vsock-device,guest-cid=N"
  exit 1
fi

echo "[*] Stopping existing tracebox processes..."
pkill -f "$(basename $TRACEBOX)" 2>/dev/null || true
sleep 1
rm -f "$RELAY_SOCK"

echo "[*] Starting traced_relay → vsock://${HOST_CID}:${HOST_PORT}..."
PERFETTO_RELAY_SOCK_NAME="vsock://${HOST_CID}:${HOST_PORT}" \
  "$TRACEBOX" traced_relay \
  >> "$RELAY_LOG" 2>&1 &

sleep 1

echo "[*] Starting traced_probes → $RELAY_SOCK..."
PERFETTO_PRODUCER_SOCK_NAME="$RELAY_SOCK" \
  "$TRACEBOX" traced_probes \
  >> "$PROBES_LOG" 2>&1 &

sleep 1

echo ""
echo "[+] Done. Check logs:"
echo "    tail -5 $RELAY_LOG    # should say: Started traced_relay, forwarding to vsock://${HOST_CID}:${HOST_PORT}"
echo "    tail -5 $PROBES_LOG   # should say: Connected to the service"
echo ""
echo "relay PID:  $(pgrep -f "$(basename $TRACEBOX)" | head -1 || echo 'not found')"
echo "probes PID: $(pgrep -f "$(basename $TRACEBOX)" | tail -1 || echo 'not found')"
