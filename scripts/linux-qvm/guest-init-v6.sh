#!/bin/sh
# Linux ARM64 QVM guest init v6
# Uses AGL kernel (virtio built-in) + networking + traced_relay
#
# Trace output: written to /dev/vda (virtio-blk)
#   offset 0   : 8-byte ASCII decimal trace size
#   offset 512 : raw .pftrace data

export PATH=/bin:/sbin:/usr/bin:/usr/sbin
export LD_LIBRARY_PATH=/lib:/lib/aarch64-linux-gnu

RELAY_MODE=1
HV_HOST_IP=10.10.10.1
RELAY_PORT=20001
GUEST_IP=10.10.10.3
NETMASK=255.255.255.0

log() { echo "LINUX-GUEST: $1"; }
log "=== Linux Guest Boot v6 ==="

mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
mount -t tmpfs tmpfs /tmp
mount -t tmpfs tmpfs /run
mount -t tracefs tracefs /sys/kernel/tracing 2>/dev/null
mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null

# Try loading modules (needed for Debian kernel, skip errors for AGL built-in)
log "=== Loading virtio modules (may skip if built-in) ==="
for KVER in 6.6.84-yocto-standard 6.1.0-42-arm64; do
    KMOD="/lib/modules/$KVER/kernel/drivers"
    if [ -d "$KMOD" ]; then
        insmod $KMOD/virtio/virtio_mmio.ko 2>/dev/null
        insmod $KMOD/block/virtio_blk.ko 2>/dev/null
        insmod $KMOD/net/virtio_net.ko 2>/dev/null
        log "Tried modules from $KVER"
        break
    fi
done
sleep 2

log "=== Block devices ==="
ls -la /dev/vd* 2>/dev/null || log "no /dev/vd*"
cat /proc/partitions 2>/dev/null

log "=== Network setup ==="
ip link 2>/dev/null
# Find virtio-net interface — try all common names
NET_FOUND=0
for IFACE in eth0 enp0s1 ens0 ens1; do
    if [ -e "/sys/class/net/$IFACE" ]; then
        log "Found interface: $IFACE"
        ip link set "$IFACE" up 2>/dev/null
        sleep 1
        ip addr add ${GUEST_IP}/24 dev "$IFACE" 2>/dev/null
        log "Configured $IFACE with $GUEST_IP rc=$?"
        sleep 2
        ip addr show "$IFACE" 2>/dev/null
        # Test connectivity
        ping -c 2 -W 3 "$HV_HOST_IP" 2>&1
        log "ping HV host: $?"
        NET_FOUND=1
        break
    fi
done
if [ "$NET_FOUND" = "0" ]; then
    log "NO NETWORK INTERFACE FOUND — listing /sys/class/net:"
    ls /sys/class/net/ 2>/dev/null
    ip link 2>/dev/null
fi

log "=== Starting Perfetto ==="
/bin/traced &
TRACED_PID=$!
sleep 2

/bin/traced_probes &
PROBES_PID=$!
sleep 2

if [ "$RELAY_MODE" = "1" ] && [ "$NET_FOUND" = "1" ] && [ -x /bin/traced_relay ]; then
    log "=== Starting relay to ${HV_HOST_IP}:${RELAY_PORT} ==="
    PERFETTO_RELAY_SOCK_NAME="${HV_HOST_IP}:${RELAY_PORT}" /bin/traced_relay &
    RELAY_PID=$!
    sleep 3
    if kill -0 "$RELAY_PID" 2>/dev/null; then
        log "RELAY_ALIVE pid=$RELAY_PID"
    else
        log "RELAY_DIED - falling back to standalone"
        RELAY_MODE=0
    fi
else
    if [ "$NET_FOUND" = "0" ]; then
        log "No network — relay disabled"
    elif [ ! -x /bin/traced_relay ]; then
        log "No traced_relay binary — relay disabled"
    fi
    RELAY_MODE=0
fi

# Standalone local trace
cat > /tmp/perfetto.cfg <<'PCFG'
duration_ms: 10000
buffers { size_kb: 16384 }
data_sources {
  config {
    name: "linux.ftrace"
    ftrace_config {
      ftrace_events: "sched/sched_switch"
      ftrace_events: "sched/sched_wakeup"
      ftrace_events: "sched/sched_process_fork"
      ftrace_events: "sched/sched_process_exit"
    }
  }
}
data_sources {
  config {
    name: "linux.process_stats"
    process_stats_config { scan_all_processes_on_start: true }
  }
}
PCFG

log "=== Capturing 10s local trace ==="
/bin/perfetto --txt -c /tmp/perfetto.cfg -o /tmp/trace.pftrace
RC=$?
log "PERFETTO_DONE=$RC"

if [ -f /tmp/trace.pftrace ]; then
    TRACE_SIZE=$(wc -c < /tmp/trace.pftrace)
    log "TRACE_SIZE=$TRACE_SIZE"
else
    TRACE_SIZE=0
    log "NO_TRACE_FILE"
fi

log "=== Writing trace to virtio-blk ==="
SAVED=0
for DEV in /dev/vda /dev/vdb /dev/sda /dev/sdb; do
    if [ -b "$DEV" ]; then
        log "Writing ${TRACE_SIZE} bytes to $DEV"
        printf "%08d" "$TRACE_SIZE" | dd of="$DEV" bs=8 count=1 2>/dev/null
        dd if=/tmp/trace.pftrace of="$DEV" bs=512 seek=1 2>/dev/null
        log "TRACE_SAVED_TO=$DEV"
        SAVED=1
        break
    fi
done
[ "$SAVED" = "0" ] && log "NO_BLOCK_DEVICE"

# Keep guest alive for relay and debugging (120s then shutdown)
if [ "$RELAY_MODE" = "1" ]; then
    log "=== Guest staying alive for relay (120s) ==="
    log "HV host can trigger multi-VM trace now"
    sleep 120
    log "Relay window closed, shutting down"
fi

# Cleanup
kill $TRACED_PID $PROBES_PID $RELAY_PID 2>/dev/null

log "=== Linux Guest v6 Done ==="
sync
echo o > /proc/sysrq-trigger
sleep 5
