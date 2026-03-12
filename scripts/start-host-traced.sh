#!/usr/bin/env bash
# start-host-traced.sh
# Start Perfetto traced with vsock relay endpoint on host
# Must run as root (for vsock port binding)
#
# Usage: sudo bash start-host-traced.sh [TRACEBOX_DIR] [VSOCK_PORT]
#
# TRACEBOX_DIR: directory containing traced, traced_probes, perfetto binaries
# VSOCK_PORT:   vsock port to listen on (default: 20001)

set -euo pipefail

TRACEBOX_DIR="${1:-/tmp/pf-v54}"
VSOCK_PORT="${2:-20001}"
PRODUCER_SOCK="/tmp/pf-producer"
CONSUMER_SOCK="/tmp/pf-consumer"
TRACED_LOG="/tmp/traced-live.log"
PROBES_LOG="/tmp/probes-live.log"

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: must run as root (required for vsock port binding)"
  exit 1
fi

if [[ ! -x "$TRACEBOX_DIR/traced" ]]; then
  echo "ERROR: $TRACEBOX_DIR/traced not found or not executable"
  exit 1
fi

echo "[*] Stopping existing traced processes..."
pkill -f "$TRACEBOX_DIR/traced$" 2>/dev/null || true
pkill -f "$TRACEBOX_DIR/traced_probes" 2>/dev/null || true
sleep 1

echo "[*] Removing stale sockets..."
rm -f "$PRODUCER_SOCK" "$CONSUMER_SOCK"

echo "[*] Starting traced (UNIX + vsock://ANY:$VSOCK_PORT)..."
PERFETTO_PRODUCER_SOCK_NAME="$PRODUCER_SOCK,vsock://4294967295:$VSOCK_PORT" \
PERFETTO_CONSUMER_SOCK_NAME="$CONSUMER_SOCK" \
  "$TRACEBOX_DIR/traced" --enable-relay-endpoint \
  >> "$TRACED_LOG" 2>&1 &

sleep 1

echo "[*] Opening consumer socket to non-root users..."
chmod 666 "$CONSUMER_SOCK"

echo "[*] Starting traced_probes (local)..."
"$TRACEBOX_DIR/traced_probes" \
  --producer-socket "$PRODUCER_SOCK" \
  >> "$PROBES_LOG" 2>&1 &

sleep 1

echo ""
echo "[+] Done. Verify with:"
echo "    ss --vsock -lnp | grep $VSOCK_PORT"
echo "    tail -3 $TRACED_LOG"
echo ""
echo "traced PID:        $(pgrep -f "$TRACEBOX_DIR/traced$" || echo 'not found')"
echo "traced_probes PID: $(pgrep -f "$TRACEBOX_DIR/traced_probes" || echo 'not found')"
