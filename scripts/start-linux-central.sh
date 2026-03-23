#!/bin/bash
# start-linux-central.sh — Start 3-VM stack with Linux guest as central traced
#
# Architecture:
#   Linux Guest  — central traced + traced_probes + perfetto CLI
#   QNX Host     — TCP proxy + traced_relay + traced_qnx_probes
#   QNX Guest    — traced_relay + traced_qnx_probes (in IFS)
#
# Environment (all required):
#   QNX_HOST      SSH host (default: localhost)
#   QNX_PORT      SSH port (default: 22)

set -e

QNX_HOST="${QNX_HOST:-localhost}"
QNX_PORT="${QNX_PORT:-22}"
QNX_GUEST_CONF="${QNX_GUEST_CONF:-/dev/shmem/qnx-guest.conf}"
LINUX_GUEST_CONF="${LINUX_GUEST_CONF:-/dev/shmem/linux-central.conf}"
LINUX_GUEST_IP="${LINUX_GUEST_IP:-10.10.10.3}"
PROXY_PORT="${PROXY_PORT:-20001}"
RELAY_PRODUCER_SOCK="/tmp/perfetto-producer"

SSH="ssh -o StrictHostKeyChecking=no -p $QNX_PORT root@$QNX_HOST"

echo "=== Starting 3-VM Stack (Linux Central Traced) ==="

# 1. Kill existing Perfetto processes
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
    echo "  Linux guest already running"
else
    $SSH "/proc/boot/echo '' > /data/linux-central-console.log 2>/dev/null" 2>/dev/null || true
    $SSH "/system/bin/qvm @${LINUX_GUEST_CONF} &" 2>/dev/null &
fi

echo "  Waiting 15s for Linux guest traced to start..."
sleep 15

# 4. Verify Linux guest is reachable
echo "[4/7] Verifying Linux guest connectivity..."
$SSH "ping -c 2 ${LINUX_GUEST_IP} 2>&1" || {
    echo "  WARN: Cannot ping Linux guest"
}

# 5. Start TCP proxy on host (for QNX guest → Linux guest relay)
echo "[5/7] Starting TCP proxy..."
$SSH "
LD_LIBRARY_PATH=/proc/boot:/data \
/data/tcp-proxy ${PROXY_PORT} ${LINUX_GUEST_IP} ${PROXY_PORT} &
" 2>/dev/null &
sleep 2

# 6. Start host traced_relay + traced_qnx_probes
echo "[6/7] Starting host traced_relay + traced_qnx_probes..."
$SSH "
PERFETTO_PRODUCER_SOCK_NAME=${RELAY_PRODUCER_SOCK} \
PERFETTO_RELAY_SOCK_NAME=${LINUX_GUEST_IP}:${PROXY_PORT} \
LD_LIBRARY_PATH=/proc/boot:/data \
/data/traced_relay &
" 2>/dev/null &
sleep 3

$SSH "
PERFETTO_PRODUCER_SOCK_NAME=${RELAY_PRODUCER_SOCK} \
LD_LIBRARY_PATH=/proc/boot:/data \
/data/traced_qnx_probes &
" 2>/dev/null &
sleep 3

# 7. Start QNX guest
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
echo "Console: $SSH 'cat /data/linux-central-console.log'"
echo "Download: scripts/capture-linux-central.sh"
