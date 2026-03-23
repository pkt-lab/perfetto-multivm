#!/bin/bash
# start-linux-central.sh — Start 3-VM stack with Linux guest as central traced
#
# Architecture:
#   Linux Guest (10.10.10.3) — central traced + traced_probes + perfetto CLI
#   QNX Host   (10.10.10.1) — TCP proxy + traced_relay + traced_qnx_probes
#   QNX Guest  (10.10.10.2) — traced_relay + traced_qnx_probes (in IFS)
#
# Prerequisites:
#   - QNX HV booted with SSH access
#   - QNX binaries uploaded to /data/ on host: traced_relay, traced_qnx_probes,
#     libperfetto.so, tcp-proxy
#   - Linux guest initrd at /dev/shmem/initrd-linux-central.gz
#   - Linux guest kernel at /dev/shmem/linux-Image
#   - QNX guest IFS at /dev/shmem/ with traced_relay + traced_qnx_probes
#   - Guest qvm configs at /dev/shmem/
#
# Usage:
#   bash start-linux-central.sh
#
# Environment:
#   QNX_PORT=2241     SSH port (default: 2241)
#   QNX_PASS=root     SSH password (default: root)

set -e

QNX_HOST="${QNX_HOST:-localhost}"
QNX_PORT="${QNX_PORT:-2241}"
QNX_PASS="${QNX_PASS:-root}"
QNX_GUEST_CONF="${QNX_GUEST_CONF:-/dev/shmem/qnx-guest.conf}"
LINUX_GUEST_CONF="${LINUX_GUEST_CONF:-/dev/shmem/linux-central.conf}"
LINUX_GUEST_IP="10.10.10.3"
PROXY_PORT="20001"

if command -v sshpass &>/dev/null && [ -n "$QNX_PASS" ]; then
    SSH="sshpass -p $QNX_PASS ssh -o StrictHostKeyChecking=no -p $QNX_PORT root@$QNX_HOST"
    SCP="sshpass -p $QNX_PASS scp -o StrictHostKeyChecking=no -P $QNX_PORT"
else
    SSH="ssh -o StrictHostKeyChecking=no -p $QNX_PORT root@$QNX_HOST"
    SCP="scp -o StrictHostKeyChecking=no -P $QNX_PORT"
fi

echo "=== Starting 3-VM Stack (Linux Central Traced) ==="

# 1. Kill existing Perfetto processes (not qvm guests)
echo "[1/7] Cleaning up old Perfetto processes..."
$SSH '
for PID in $(/proc/boot/pidin -F "%a %N" 2>/dev/null | /proc/boot/grep -E "traced|probes|tcp-proxy" | while read pid name; do echo $pid; done); do
    kill -9 $PID 2>/dev/null
done
/proc/boot/rm -f /data/sock/perfetto-producer /data/sock/perfetto-consumer 2>/dev/null
' 2>/dev/null || true
sleep 2

# 2. Add routes for guest networking
echo "[2/7] Adding guest network routes..."
$SSH '
/system/bin/route add -host 10.10.10.2 -iface vp1 2>/dev/null
/system/bin/route add -host 10.10.10.3 -iface vp0 2>/dev/null
' 2>/dev/null || true

# 3. Start Linux guest FIRST (it's the central traced)
echo "[3/7] Starting Linux guest (central traced)..."
RUNNING_QVMS=$($SSH '/proc/boot/pidin -p qvm arg 2>&1' || true)

if echo "$RUNNING_QVMS" | grep -q "linux"; then
    echo "  Linux guest already running — kill it first for fresh start"
    echo "  (or skip this step if initrd already has central traced)"
else
    $SSH "/proc/boot/echo '' > /data/linux-central-console.log 2>/dev/null" 2>/dev/null || true
    $SSH "/system/bin/qvm @${LINUX_GUEST_CONF} &" 2>/dev/null &
fi

# Wait for Linux guest traced to come up
echo "  Waiting for Linux guest traced to start (15s)..."
sleep 15

# Verify Linux guest is reachable
echo "[4/7] Verifying Linux guest connectivity..."
$SSH "ping -c 2 ${LINUX_GUEST_IP} 2>&1" || {
    echo "  WARN: Cannot ping Linux guest — traced_relay connections may fail"
}

# 5. Start TCP proxy on host (for QNX guest → Linux guest relay)
echo "[5/7] Starting TCP proxy on host (0.0.0.0:${PROXY_PORT} → ${LINUX_GUEST_IP}:${PROXY_PORT})..."
$SSH "
LD_LIBRARY_PATH=/proc/boot:/data \
/data/tcp-proxy ${PROXY_PORT} ${LINUX_GUEST_IP} ${PROXY_PORT} &
" 2>/dev/null &
sleep 2

# 6. Start host traced_relay → Linux guest (direct, not via proxy)
echo "[6/7] Starting host traced_relay + traced_qnx_probes..."
$SSH "
PERFETTO_RELAY_SOCK_NAME=${LINUX_GUEST_IP}:${PROXY_PORT} \
LD_LIBRARY_PATH=/proc/boot:/data \
/data/traced_relay &
" 2>/dev/null &
sleep 3

$SSH "
PERFETTO_PRODUCER_SOCK_NAME=/tmp/perfetto-producer \
LD_LIBRARY_PATH=/proc/boot:/data \
/data/traced_qnx_probes &
" 2>/dev/null &
sleep 3

# 7. Start QNX guest (if not running)
echo "[7/7] Starting QNX guest..."
if echo "$RUNNING_QVMS" | grep -q "$QNX_GUEST_CONF"; then
    echo "  QNX guest already running"
else
    $SSH "/system/bin/qvm @${QNX_GUEST_CONF} &" 2>/dev/null &
fi
sleep 5

# Verify
echo ""
echo "=== Verification ==="
$SSH '/proc/boot/pidin -F "%a %N" 2>&1' 2>/dev/null | grep -E "traced|probes|qvm|tcp-proxy" || true
echo ""
echo "=== Stack Ready ==="
echo ""
echo "Linux guest console: ssh -p $QNX_PORT root@$QNX_HOST 'cat /data/linux-central-console.log'"
echo ""
echo "To capture trace from GB10 (forward port to Linux guest via host):"
echo "  1. SSH tunnel: ssh -p $QNX_PORT -L 20002:10.10.10.3:20001 root@$QNX_HOST"
echo "  2. Not needed — capture happens inside Linux guest (see console log)"
echo ""
echo "Trace will be in Linux guest at /data/trace.pftrace"
echo "Download via: scripts/capture-linux-central.sh"
