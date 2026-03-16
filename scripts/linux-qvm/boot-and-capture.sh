#!/bin/bash
# boot-and-capture.sh — Boot Linux QVM guest and extract Perfetto trace
#
# Runs on AMD host. Connects to QNX HV via SSH (sshpass).
# Boots a Linux ARM64 QVM guest, waits for completion, extracts trace.
#
# Prerequisites on QNX HV:
#   /dev/shmem/linux-Image       — ARM64 kernel (31MB)
#   /dev/shmem/initrd-linux-qvm.gz — custom initrd (44MB)
#   /data/linux-trace.img        — 16MB zero-filled trace image
#
# Usage:
#   QNX_PASS=root QNX_PORT=2240 QNX_HOST=localhost bash boot-and-capture.sh

set -e

QNX_HOST="${QNX_HOST:-localhost}"
QNX_PORT="${QNX_PORT:-2240}"
QNX_PASS="${QNX_PASS:-root}"
OUTPUT="${OUTPUT:-/tmp/trace-linux-qvm.pftrace}"
WAIT_SEC="${WAIT_SEC:-35}"

SSH="sshpass -p $QNX_PASS ssh -o StrictHostKeyChecking=no -p $QNX_PORT root@$QNX_HOST"
SCP="sshpass -p $QNX_PASS scp -o StrictHostKeyChecking=no -P $QNX_PORT"

echo "=== Linux QVM Boot & Capture ==="

# 1. Prepare trace image
echo "[1/5] Preparing trace image on QNX HV..."
$SSH "dd if=/dev/zero of=/data/linux-trace.img bs=1M count=16 2>&1" | tail -1

# 2. Write QVM config
echo "[2/5] Writing QVM config..."
$SSH "cat > /data/linux-guest.conf << 'QVMEOF'
system linux-guest
ram 0x80000000,512m
cpu
cpu
guest load /dev/shmem/linux-Image
initrd load /dev/shmem/initrd-linux-qvm.gz
cmdline \"console=ttyAMA0 earlycon=pl011,0x1c090000 loglevel=8 init=/init\"

vdev vdev-pl011
  loc 0x1c090000
  intr gic:37
  hostdev >/data/linux-console.log

vdev virtio-blk
  loc 0x1c0c0000
  intr gic:40
  hostdev /data/linux-trace.img
  name trace-disk
QVMEOF
"

# 3. Boot guest
echo "[3/5] Booting Linux guest..."
$SSH "
  slay -f qvm 2>/dev/null; sleep 1
  > /data/linux-console.log
  qvm @/data/linux-guest.conf > /data/linux-qvm.log 2>&1 &
  echo QVM_PID=\$!
"

echo "  Waiting ${WAIT_SEC}s for boot + trace..."
sleep "$WAIT_SEC"

# 4. Check results
echo "[4/5] Checking results..."
$SSH "
  echo '--- QVM log ---'
  cat /data/linux-qvm.log
  echo '--- Console tail ---'
  tail -20 /data/linux-console.log
"

# 5. Extract trace
echo "[5/5] Extracting trace..."
TRACE_IMG="/tmp/linux-trace-raw.img"
$SCP "root@$QNX_HOST:/data/linux-trace.img" "$TRACE_IMG"

TRACE_SIZE=$(dd if="$TRACE_IMG" bs=8 count=1 2>/dev/null | tr -d "\0" | sed 's/^0*//')
if [ -z "$TRACE_SIZE" ] || [ "$TRACE_SIZE" = "0" ]; then
  echo "ERROR: No trace written (size=0)" >&2
  exit 1
fi

echo "  Trace size: $TRACE_SIZE bytes"
SECTORS=$(( (TRACE_SIZE + 511) / 512 ))
dd if="$TRACE_IMG" of="$OUTPUT" bs=512 skip=1 count="$SECTORS" 2>/dev/null
truncate -s "$TRACE_SIZE" "$OUTPUT"

# Validate
python3 - << EOF
data = open("$OUTPUT", "rb").read()
assert data[0] == 0x0a, f"Not a Perfetto trace (first byte: 0x{data[0]:02x})"
print(f"  Valid Perfetto trace: {len(data)} bytes")
EOF

echo "=== Done: $OUTPUT ==="
echo "  Open with: https://ui.perfetto.dev"
