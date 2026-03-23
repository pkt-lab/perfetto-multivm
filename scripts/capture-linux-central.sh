#!/bin/bash
# capture-linux-central.sh — Download trace from Linux-central 3-VM stack
#
# The Linux guest auto-captures on boot and copies the trace to:
#   1. The virtio-blk shared disk (/data/linux-trace.img on host)
#   2. TCP:9999 via netcat (nc 10.10.10.3 9999 > trace.pftrace)
#
# This script uses method 2 (nc via QNX host) then falls back to method 1.
#
# Usage:
#   bash capture-linux-central.sh [output.pftrace]
#
# Environment:
#   QNX_PORT=2241    SSH port to QNX HV (default: 2241)
#   QNX_PASS=root    SSH password (default: root)

set -e

QNX_HOST="${QNX_HOST:-localhost}"
QNX_PORT="${QNX_PORT:-2241}"
QNX_PASS="${QNX_PASS:-root}"
OUTPUT="${1:-/tmp/linux-central-3vm.pftrace}"
LINUX_GUEST_IP="10.10.10.3"

if command -v sshpass &>/dev/null && [ -n "$QNX_PASS" ]; then
    SSH="sshpass -p $QNX_PASS ssh -o StrictHostKeyChecking=no -p $QNX_PORT root@$QNX_HOST"
    SCP="sshpass -p $QNX_PASS scp -o StrictHostKeyChecking=no -P $QNX_PORT"
else
    SSH="ssh -o StrictHostKeyChecking=no -p $QNX_PORT root@$QNX_HOST"
    SCP="scp -o StrictHostKeyChecking=no -P $QNX_PORT"
fi

echo "=== Downloading Linux-Central 3-VM Trace ==="

# Check Linux guest console for capture status
echo "[1/3] Checking capture status..."
CONSOLE=$($SSH 'cat /data/linux-central-console.log 2>/dev/null' 2>/dev/null || true)
if echo "$CONSOLE" | grep -q "CAPTURE_OK"; then
    echo "  Trace captured successfully"
    echo "$CONSOLE" | grep "CAPTURE_OK" | sed 's/^/    /'
elif echo "$CONSOLE" | grep -q "CAPTURE_FAILED"; then
    echo "  ERROR: Capture failed"
    echo "$CONSOLE" | tail -20 | sed 's/^/    /'
    exit 2
else
    echo "  WARN: Capture status unclear — may still be in progress"
    echo "$CONSOLE" | tail -10 | sed 's/^/    /'
fi

# Method 1: Try netcat transfer from guest
echo "[2/3] Trying netcat transfer from guest..."
$SSH "
# Use QNX nc to connect to Linux guest and download trace
# QNX host can reach Linux guest at ${LINUX_GUEST_IP}
timeout 60 /proc/boot/cat < /dev/tcp/${LINUX_GUEST_IP}/9999 > /dev/shmem/linux-central-trace.pftrace 2>/dev/null
" 2>/dev/null || true

# Check if that worked
REMOTE_SIZE=$($SSH 'ls -l /dev/shmem/linux-central-trace.pftrace 2>/dev/null | awk "{print \$5}"' 2>/dev/null || echo "0")
if [ "${REMOTE_SIZE:-0}" -gt 1000 ]; then
    echo "  Downloaded via netcat: ${REMOTE_SIZE} bytes"
    $SSH 'cat /dev/shmem/linux-central-trace.pftrace' > "$OUTPUT" 2>/dev/null
else
    echo "  Netcat transfer failed or empty, trying virtio-blk disk..."
    # Method 2: Read from shared disk image
    echo "[3/3] Reading from virtio-blk disk image..."
    # The trace.img is an ext4 filesystem on the host at /data/linux-trace.img
    # We can copy it to local and mount it, or use debugfs to extract
    $SCP "root@${QNX_HOST}:/data/linux-trace.img" /tmp/linux-trace.img 2>/dev/null || {
        echo "  ERROR: Cannot download trace disk image"
        echo "  Try manual download:"
        echo "    ssh -p $QNX_PORT root@$QNX_HOST 'cat /data/linux-trace.img' > /tmp/linux-trace.img"
        exit 1
    }
    # Extract trace from disk image
    mkdir -p /tmp/trace-mount
    sudo mount -o ro,loop /tmp/linux-trace.img /tmp/trace-mount 2>/dev/null && {
        if [ -f /tmp/trace-mount/trace.pftrace ]; then
            cp /tmp/trace-mount/trace.pftrace "$OUTPUT"
            sudo umount /tmp/trace-mount
            echo "  Extracted trace from disk image"
        else
            sudo umount /tmp/trace-mount
            echo "  ERROR: trace.pftrace not found on disk image"
            exit 1
        fi
    } || {
        echo "  Cannot mount disk image (may need sudo)"
        echo "  Alternative: mount /tmp/linux-trace.img manually"
        exit 1
    }
fi

if [ -f "$OUTPUT" ]; then
    SIZE=$(du -h "$OUTPUT" | cut -f1)
    echo ""
    echo "=== Trace downloaded ==="
    echo "  File: $OUTPUT ($SIZE)"
    echo "  Validate: bash scripts/validate-trace.sh $OUTPUT 3"
    echo "  View: https://ui.perfetto.dev"
fi
