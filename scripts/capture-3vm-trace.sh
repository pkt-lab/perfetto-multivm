#!/bin/bash
# capture-3vm-trace.sh — Capture a unified 3-VM Perfetto trace
#
# Captures scheduling data from QNX HV host + QNX guest + Linux guest
# in a single .pftrace file via the Perfetto relay architecture.
#
# Prerequisites:
#   - QNX HV running with SSH access (port 2241)
#   - QNX guest running with traced_relay + traced_qnx_probes
#   - Linux guest running with traced_relay + traced_probes
#   - Host traced running with --enable-relay-endpoint on TCP:20001
#   - Host traced_qnx_probes connected to local producer socket
#
# Usage:
#   bash capture-3vm-trace.sh [output.pftrace]
#
# Environment:
#   QNX_PORT=2241    SSH port to QNX HV (default: 2241)
#   QNX_PASS=root    SSH password (default: root)
#   DURATION=30      Trace duration in seconds (default: 30)

set -e

QNX_HOST="${QNX_HOST:-localhost}"
QNX_PORT="${QNX_PORT:-2241}"
QNX_PASS="${QNX_PASS:-root}"
DURATION="${DURATION:-30}"
OUTPUT="${1:-/tmp/3vm-trace.pftrace}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$SCRIPT_DIR/../configs/multivm-3vm.pbtxt"

SSH="ssh -p $QNX_PORT -o StrictHostKeyChecking=no root@$QNX_HOST"

echo "=== 3-VM Trace Capture ==="
echo "  Duration: ${DURATION}s"
echo "  Output  : $OUTPUT"

# 1. Upload trace config
echo "[1/4] Uploading trace config..."
cat "$CONFIG" | $SSH '/proc/boot/cat > /dev/shmem/multivm-3vm.pbtxt'

# 2. Verify all Perfetto processes are running
echo "[2/4] Verifying Perfetto stack..."
PROCS=$($SSH '/proc/boot/pidin -F "%a %N" 2>&1')
echo "$PROCS" | grep -q "traced" || { echo "ERROR: traced not running on host"; exit 1; }
echo "$PROCS" | grep -q "probes" || { echo "ERROR: traced_qnx_probes not running on host"; exit 1; }
echo "  Host traced + probes: OK"

# Check guests are running
QVMS=$($SSH '/proc/boot/pidin -p qvm arg 2>&1')
echo "$QVMS"
QVM_COUNT=$(echo "$QVMS" | grep -c "qvm @" || true)
echo "  QVM guests running: $QVM_COUNT"

# 3. Capture trace
echo "[3/4] Capturing ${DURATION}s trace..."
DURATION_MS=$((DURATION * 1000))
$SSH "
PERFETTO_CONSUMER_SOCK_NAME=/data/sock/perfetto-consumer \
LD_LIBRARY_PATH=/proc/boot:/data \
/data/perfetto --txt -c /dev/shmem/multivm-3vm.pbtxt -o /dev/shmem/3vm-trace.pftrace 2>&1
"

# 4. Download trace
echo "[4/4] Downloading trace..."
$SSH '/proc/boot/cat /dev/shmem/3vm-trace.pftrace' > "$OUTPUT"
SIZE=$(du -h "$OUTPUT" | cut -f1)
echo "  Downloaded: $OUTPUT ($SIZE)"

# Cleanup remote trace
$SSH '/proc/boot/rm /dev/shmem/3vm-trace.pftrace 2>/dev/null'

echo "=== Capture complete ==="
echo "  Open with: https://ui.perfetto.dev"
echo "  Analyze with: trace_processor_shell $OUTPUT"
