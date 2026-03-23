#!/bin/sh
# Linux guest init — CENTRAL traced role
#
# This guest runs the central traced service that QNX machines relay to.
# Topology:
#   - traced listens on TCP 0.0.0.0:20001 (--enable-relay-endpoint)
#   - traced_probes connects locally for Linux ftrace + process_stats
#   - perfetto CLI triggers auto-capture after relay settle time
#
# Network: 10.10.10.3/24 via vdevpeer-net to QNX host (10.10.10.1)
# Trace output: served via netcat on TCP:9999

export LD_LIBRARY_PATH=/lib:/usr/lib
export PATH=/bin:/sbin:/usr/bin:/usr/sbin

LISTEN_PORT="${LISTEN_PORT:-20001}"
GUEST_IP="${GUEST_IP:-10.10.10.3}"
HOST_IP="${HOST_IP:-10.10.10.1}"
SETTLE_TIME="${SETTLE_TIME:-30}"
TRACE_DURATION="${TRACE_DURATION:-30}"

log() { echo "LINUX-CENTRAL: $1"; }
log "=== Linux Central Traced Guest ==="

# Mount essential filesystems
mkdir -p /proc /sys /dev /tmp /run /data 2>/dev/null
busybox mount -t proc proc /proc
busybox mount -t sysfs sysfs /sys
busybox mount -t devtmpfs devtmpfs /dev
busybox mount -t tmpfs tmpfs /tmp
busybox mount -t tmpfs tmpfs /run
busybox mount -t tmpfs tmpfs /data
busybox mount -t tracefs tracefs /sys/kernel/tracing 2>/dev/null
busybox mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null

# Try loading kernel modules
for KVER in 6.6.84-yocto-standard 6.1.0-42-arm64; do
    KMOD="/lib/modules/$KVER/kernel/drivers"
    if [ -d "$KMOD" ]; then
        insmod $KMOD/virtio/virtio_mmio.ko 2>/dev/null
        insmod $KMOD/net/virtio_net.ko 2>/dev/null
        break
    fi
done
sleep 2

# Network setup — find first available interface
log "=== Network setup ==="
NET_OK=0
for IFACE in eth0 enp0s1 ens0 ens1; do
    if [ -e "/sys/class/net/${IFACE}" ]; then
        log "Found interface: ${IFACE}"
        busybox ip link set "${IFACE}" up 2>/dev/null
        sleep 1
        busybox ip addr add "${GUEST_IP}/24" dev "${IFACE}" 2>/dev/null
        sleep 1
        busybox ip addr show "${IFACE}" 2>/dev/null
        ping -c 2 -W 3 "${HOST_IP}" 2>&1
        if [ $? -eq 0 ]; then
            log "Network OK: ${IFACE} ${GUEST_IP} -> ${HOST_IP} reachable"
        else
            log "WARN: ping to ${HOST_IP} failed, relay may still connect"
        fi
        NET_OK=1
        break
    fi
done

if [ "${NET_OK}" = "0" ]; then
    log "ERROR: no network interface found — relay machines cannot connect"
fi

# Create socket directory
mkdir -p /tmp/perfetto-sockets

# Start central traced with relay endpoint on TCP
log "=== Starting central traced on 0.0.0.0:${LISTEN_PORT} ==="
PERFETTO_PRODUCER_SOCK_NAME=/tmp/perfetto-sockets/perfetto-producer,0.0.0.0:${LISTEN_PORT} \
PERFETTO_CONSUMER_SOCK_NAME=/tmp/perfetto-sockets/perfetto-consumer \
traced --enable-relay-endpoint &
TRACED_PID=$!
sleep 3

if kill -0 "${TRACED_PID}" 2>/dev/null; then
    log "TRACED_ALIVE pid=${TRACED_PID} listening on TCP:${LISTEN_PORT}"
else
    log "TRACED_DIED — check binary and libperfetto.so"
    PERFETTO_PRODUCER_SOCK_NAME=/tmp/perfetto-sockets/perfetto-producer,0.0.0.0:${LISTEN_PORT} \
    PERFETTO_CONSUMER_SOCK_NAME=/tmp/perfetto-sockets/perfetto-consumer \
    traced --enable-relay-endpoint 2>&1 &
    TRACED_PID=$!
    sleep 5
fi

# Start local traced_probes (for Linux ftrace + process_stats)
log "=== Starting local traced_probes ==="
PERFETTO_PRODUCER_SOCK_NAME=/tmp/perfetto-sockets/perfetto-producer \
traced_probes &
PROBES_PID=$!
sleep 2

if kill -0 "${PROBES_PID}" 2>/dev/null; then
    log "PROBES_ALIVE pid=${PROBES_PID}"
else
    log "PROBES_DIED"
fi

# Copy bundled trace config
if [ -f /etc/linux-central-3vm.pbtxt ]; then
    cp /etc/linux-central-3vm.pbtxt /data/
    log "Trace config: /data/linux-central-3vm.pbtxt"
fi

log "=== Central traced ready ==="
log "Waiting ${SETTLE_TIME}s for QNX relay machines to connect..."

# Wait for relay machines to connect
sleep "${SETTLE_TIME}"

# Auto-capture trace
TRACE_OUT="/data/trace.pftrace"
log "=== Starting ${TRACE_DURATION}s trace capture ==="
PERFETTO_CONSUMER_SOCK_NAME=/tmp/perfetto-sockets/perfetto-consumer \
perfetto --txt -c /data/linux-central-3vm.pbtxt -o "${TRACE_OUT}" 2>&1
CAPTURE_RC=$?

if [ ${CAPTURE_RC} -eq 0 ] && [ -f "${TRACE_OUT}" ]; then
    TRACE_SIZE=$(busybox ls -lh "${TRACE_OUT}" | busybox awk '{print $5}')
    log "CAPTURE_OK size=${TRACE_SIZE} file=${TRACE_OUT}"

    # Serve trace via netcat for download
    # From QNX host: nc 10.10.10.3 9999 > trace.pftrace
    log "Serving trace on TCP:9999 — download with: nc ${GUEST_IP} 9999 > trace.pftrace"
    while true; do
        busybox nc -l -p 9999 < "${TRACE_OUT}" 2>/dev/null
        log "nc: connection served, re-listening..."
    done &
    NC_PID=$!
else
    log "CAPTURE_FAILED rc=${CAPTURE_RC}"
fi

log "=== Trace capture complete ==="
log "Keeping guest alive for file retrieval (300s)..."

# Keep alive for trace download
sleep 300

log "=== Shutting down ==="
kill ${NC_PID} ${PROBES_PID} ${TRACED_PID} 2>/dev/null
sync
