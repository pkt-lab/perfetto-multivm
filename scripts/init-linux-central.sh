#!/bin/sh
# Linux guest init — CENTRAL traced role
#
# Runs upstream Perfetto traced as the central trace service.
# QNX machines connect as relay clients via TCP.
#
# Trace output served via netcat on TCP:9999 for download.

export PATH=/bin:/sbin
export LD_LIBRARY_PATH=/lib:/lib/aarch64-linux-gnu

LISTEN_PORT="${LISTEN_PORT:-20001}"
GUEST_IP="${GUEST_IP:-10.10.10.3}"
HOST_IP="${HOST_IP:-10.10.10.1}"
SETTLE_TIME="${SETTLE_TIME:-30}"
PRODUCER_SOCK=/tmp/perfetto-sockets/perfetto-producer
CONSUMER_SOCK=/tmp/perfetto-sockets/perfetto-consumer

log() { echo "LINUX-CENTRAL: $1"; }
log "=== Linux Central Traced Guest ==="

# Mount filesystems
mkdir -p /proc /sys /dev /tmp /run /data 2>/dev/null
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
mount -t tmpfs tmpfs /tmp
mount -t tmpfs tmpfs /run
mount -t tmpfs tmpfs /data
mount -t tracefs tracefs /sys/kernel/tracing 2>/dev/null
mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null

# Load modules
for KVER in 6.6.84-yocto-standard; do
    KMOD="/lib/modules/$KVER/kernel/drivers"
    if [ -d "$KMOD" ]; then
        insmod $KMOD/virtio/virtio_mmio.ko 2>/dev/null
        insmod $KMOD/net/virtio_net.ko 2>/dev/null
        break
    fi
done
sleep 2

# Network
log "=== Network setup ==="
for IFACE in eth0 enp0s1 ens0 ens1; do
    if [ -e "/sys/class/net/$IFACE" ]; then
        log "Found: $IFACE"
        ip link set "$IFACE" up 2>/dev/null
        sleep 1
        ip addr add "${GUEST_IP}/24" dev "$IFACE" 2>/dev/null
        ip addr show "$IFACE" 2>/dev/null
        ping -c 2 -W 3 "$HOST_IP" 2>&1
        log "ping host rc=$?"
        break
    fi
done

mkdir -p /tmp/perfetto-sockets

# Start central traced
log "=== Starting traced on 0.0.0.0:${LISTEN_PORT} ==="
PERFETTO_PRODUCER_SOCK_NAME=${PRODUCER_SOCK},0.0.0.0:${LISTEN_PORT} \
PERFETTO_CONSUMER_SOCK_NAME=${CONSUMER_SOCK} \
traced --enable-relay-endpoint &
TRACED_PID=$!
sleep 3

if kill -0 "$TRACED_PID" 2>/dev/null; then
    log "TRACED_ALIVE pid=$TRACED_PID"
else
    log "TRACED_DIED"
fi

# Start probes
log "=== Starting traced_probes ==="
PERFETTO_PRODUCER_SOCK_NAME=${PRODUCER_SOCK} \
traced_probes &
PROBES_PID=$!
sleep 2
if kill -0 "$PROBES_PID" 2>/dev/null; then
    log "PROBES_ALIVE pid=$PROBES_PID"
else
    log "PROBES_DIED"
fi

# Config
cp /etc/multivm-3vm.pbtxt /data/ 2>/dev/null
log "=== Central traced ready ==="
log "Waiting ${SETTLE_TIME}s for relay machines..."
sleep "$SETTLE_TIME"

# Auto-capture
TRACE_OUT=/data/trace.pftrace
log "=== Starting 30s trace capture ==="
PERFETTO_CONSUMER_SOCK_NAME=${CONSUMER_SOCK} \
perfetto --txt -c /data/multivm-3vm.pbtxt -o "$TRACE_OUT" 2>&1
RC=$?

NC_PID=""
if [ $RC -eq 0 ] && [ -f "$TRACE_OUT" ]; then
    TRACE_SIZE=$(ls -lh "$TRACE_OUT" | awk '{print $5}')
    log "CAPTURE_OK size=$TRACE_SIZE"
    log "Serving on TCP:9999"
    while true; do
        nc -l -p 9999 < "$TRACE_OUT" 2>/dev/null
    done &
    NC_PID=$!
else
    log "CAPTURE_FAILED rc=$RC"
fi

log "=== Keeping alive 300s ==="
sleep 300
kill $NC_PID $PROBES_PID $TRACED_PID 2>/dev/null
