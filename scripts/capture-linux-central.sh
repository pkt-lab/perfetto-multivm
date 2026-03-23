#!/bin/bash
# capture-linux-central.sh — Download trace from Linux-central 3-VM stack
#
# The Linux guest auto-captures and serves the trace via netcat on TCP:9999.
# This script downloads it through an SSH tunnel via the QNX host.
#
# Usage:
#   bash capture-linux-central.sh [output.pftrace]
#
# Environment:
#   QNX_HOST      SSH host (default: localhost)
#   QNX_PORT      SSH port (default: 22)

set -e

QNX_HOST="${QNX_HOST:-localhost}"
QNX_PORT="${QNX_PORT:-22}"
OUTPUT="${1:-/tmp/linux-central-3vm.pftrace}"
LINUX_GUEST_IP="${LINUX_GUEST_IP:-10.10.10.3}"
NC_TIMEOUT="${NC_TIMEOUT:-90}"

SSH="ssh -o StrictHostKeyChecking=no -p $QNX_PORT root@$QNX_HOST"

echo "=== Downloading Linux-Central 3-VM Trace ==="

# Check capture status
echo "[1/2] Checking capture status..."
CONSOLE=$($SSH 'cat /data/linux-central-console.log 2>/dev/null' 2>/dev/null || true)
if echo "$CONSOLE" | grep -q "CAPTURE_OK"; then
    echo "$CONSOLE" | grep "CAPTURE_OK" | sed 's/^/  /'
elif echo "$CONSOLE" | grep -q "CAPTURE_FAILED"; then
    echo "  ERROR: Capture failed"
    echo "$CONSOLE" | tail -5 | sed 's/^/    /'
    exit 2
else
    echo "  WARN: Capture may still be in progress"
fi

# Download via SSH tunnel + netcat
echo "[2/2] Downloading via SSH tunnel..."
$SSH -L 9999:${LINUX_GUEST_IP}:9999 -N &
TUNNEL_PID=$!
sleep 3

nc -w "$NC_TIMEOUT" localhost 9999 > "$OUTPUT" 2>/dev/null || true
kill $TUNNEL_PID 2>/dev/null

if [ -f "$OUTPUT" ] && [ -s "$OUTPUT" ]; then
    SIZE=$(du -h "$OUTPUT" | cut -f1)
    echo "  File: $OUTPUT ($SIZE)"
    echo "  Validate: bash scripts/validate-trace.sh $OUTPUT 3"
else
    echo "  ERROR: Download failed or empty"
    rm -f "$OUTPUT"
    exit 1
fi
