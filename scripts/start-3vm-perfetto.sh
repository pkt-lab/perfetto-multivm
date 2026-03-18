#!/bin/bash
# start-3vm-perfetto.sh — Start the full 3-VM Perfetto tracing stack
#
# Starts on QNX HV host (via SSH):
#   1. Host traced with relay endpoint (TCP:20001)
#   2. Host traced_qnx_probes
#   3. QNX guest (with traced_relay + traced_qnx_probes in IFS)
#   4. Linux guest (with traced_relay + traced_probes in initrd)
#
# Prerequisites:
#   - QNX HV booted with SSH access
#   - Perfetto binaries on HV at /data/ (traced, traced_qnx_probes, perfetto)
#   - QNX guest IFS at /dev/shmem/ with traced_relay + traced_qnx_probes
#   - Linux guest Image + initrd at /dev/shmem/
#   - QNX guest qvm config at /dev/shmem/
#   - Linux guest qvm config at /dev/shmem/
#
# Usage:
#   bash start-3vm-perfetto.sh
#
# Environment:
#   QNX_PORT=2241     SSH port (default: 2241)
#   QNX_PASS=root     SSH password (default: root)
#   QNX_GUEST_CONF    QNX guest qvm config path on HV
#   LINUX_GUEST_CONF  Linux guest qvm config path on HV

set -e

QNX_HOST="${QNX_HOST:-localhost}"
QNX_PORT="${QNX_PORT:-2241}"
QNX_PASS="${QNX_PASS:-root}"
QNX_GUEST_CONF="${QNX_GUEST_CONF:-/dev/shmem/qnx-guest.conf}"
LINUX_GUEST_CONF="${LINUX_GUEST_CONF:-/dev/shmem/linux-guest.conf}"

# Use sshpass if available, otherwise plain ssh
if command -v sshpass &>/dev/null && [ -n "$QNX_PASS" ]; then
    SSH="sshpass -p $QNX_PASS ssh -o StrictHostKeyChecking=no -p $QNX_PORT root@$QNX_HOST"
else
    SSH="ssh -o StrictHostKeyChecking=no -p $QNX_PORT root@$QNX_HOST"
fi

echo "=== Starting 3-VM Perfetto Stack ==="

# 1. Kill existing Perfetto processes (not qvm guests)
echo "[1/5] Cleaning up old Perfetto processes..."
$SSH '
for PID in $(/proc/boot/pidin -F "%a %N" 2>/dev/null | /proc/boot/grep -E "traced|probes" | while read pid name; do echo $pid; done); do
    kill -9 $PID 2>/dev/null
done
/proc/boot/rm -f /data/sock/perfetto-producer /data/sock/perfetto-consumer 2>/dev/null
' 2>/dev/null || true

sleep 2

# 2. Start host traced with relay endpoint
echo "[2/5] Starting host traced (Unix + TCP:20001)..."
$SSH '
PERFETTO_PRODUCER_SOCK_NAME=/data/sock/perfetto-producer,0.0.0.0:20001 \
PERFETTO_CONSUMER_SOCK_NAME=/data/sock/perfetto-consumer \
LD_LIBRARY_PATH=/proc/boot:/data \
/data/qnx-fix-traced --enable-relay-endpoint &
' 2>/dev/null &
sleep 3

# 3. Start host traced_qnx_probes
echo "[3/5] Starting host traced_qnx_probes..."
$SSH '
PERFETTO_PRODUCER_SOCK_NAME=/data/sock/perfetto-producer \
LD_LIBRARY_PATH=/proc/boot:/data \
/data/traced_qnx_probes_fixed &
' 2>/dev/null &
sleep 3

# 4. Add routes for guest networking
echo "[4/5] Adding guest network routes..."
$SSH '/system/bin/route add -host 10.10.10.2 -iface vp1 2>/dev/null; /system/bin/route add -host 10.10.10.3 -iface vp0 2>/dev/null' 2>/dev/null || true

# 5. Start guest VMs (if not already running)
echo "[5/5] Starting guest VMs..."
RUNNING_QVMS=$($SSH '/proc/boot/pidin -p qvm arg 2>&1' || true)

if echo "$RUNNING_QVMS" | grep -q "$QNX_GUEST_CONF"; then
    echo "  QNX guest already running"
else
    echo "  Starting QNX guest: $QNX_GUEST_CONF"
    $SSH "/system/bin/qvm @$QNX_GUEST_CONF &" 2>/dev/null &
fi

if echo "$RUNNING_QVMS" | grep -q "$LINUX_GUEST_CONF"; then
    echo "  Linux guest already running"
else
    # Ensure console log file exists
    CONSOLE_LOG=$(grep "hostdev >" "$LINUX_GUEST_CONF" 2>/dev/null | sed 's/.*>//' || echo "/data/linux-console.log")
    $SSH "/proc/boot/echo '' > /data/linux-console.log 2>/dev/null" 2>/dev/null || true
    echo "  Starting Linux guest: $LINUX_GUEST_CONF"
    $SSH "/system/bin/qvm @$LINUX_GUEST_CONF &" 2>/dev/null &
fi

sleep 5

# Verify
echo ""
echo "=== Verification ==="
$SSH '/proc/boot/pidin -F "%a %N" 2>&1' 2>/dev/null | grep -E "traced|probes|qvm" || true
echo ""
echo "Stack ready. Capture trace with:"
echo "  bash scripts/capture-3vm-trace.sh /tmp/3vm-trace.pftrace"
