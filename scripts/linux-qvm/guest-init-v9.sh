#!/bin/sh
# Linux ARM64 QVM guest init v9
# vsock relay mode + TCP fallback + low-churn workloads
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
export LD_LIBRARY_PATH=/lib:/lib/aarch64-linux-gnu

RELAY_MODE=1
HV_HOST_IP=10.10.10.1
RELAY_PORT=20001
GUEST_IP=10.10.10.3
NETMASK=255.255.255.0
# vsock: CID 2 = host, port 20001
VSOCK_ADDR="vsock://2:${RELAY_PORT}"

log() { echo "LINUX-GUEST: $1"; }
log "=== Linux Guest Boot v9 (vsock+TCP) ==="

mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
mount -t tmpfs tmpfs /tmp
mount -t tmpfs tmpfs /run
mount -t tracefs tracefs /sys/kernel/tracing 2>/dev/null
mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null

# Try loading modules
for KVER in 6.6.84-yocto-standard 6.1.0-42-arm64; do
    KMOD="/lib/modules/$KVER/kernel/drivers"
    if [ -d "$KMOD" ]; then
        insmod $KMOD/virtio/virtio_mmio.ko 2>/dev/null
        insmod $KMOD/block/virtio_blk.ko 2>/dev/null
        insmod $KMOD/net/virtio_net.ko 2>/dev/null
        break
    fi
done
sleep 2

# Check vsock device presence
VSOCK_AVAIL=0
if [ -e /sys/class/vsock ]; then
    log "vsock: /sys/class/vsock present"
    VSOCK_AVAIL=1
elif [ -e /sys/devices/platform ]; then
    # Check for virtio-vsock device in platform devices
    for dev in /sys/bus/virtio/devices/virtio*; do
        if [ -f "$dev/device" ]; then
            DEVID=$(cat "$dev/device" 2>/dev/null)
            if [ "$DEVID" = "0x0013" ]; then
                log "vsock: found virtio device id 19 at $dev"
                VSOCK_AVAIL=1
                break
            fi
        fi
    done
fi
if [ "$VSOCK_AVAIL" = "0" ]; then
    log "vsock: no vsock device detected, will use TCP"
fi

log "=== Network setup ==="
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
        ping -c 2 -W 3 "$HV_HOST_IP" 2>&1
        log "ping HV host: $?"
        NET_FOUND=1
        break
    fi
done

log "=== Starting Perfetto ==="

# Try vsock relay first, fall back to TCP
if [ "$RELAY_MODE" = "1" ] && [ -x /bin/traced_relay ]; then
    if [ "$VSOCK_AVAIL" = "1" ]; then
        log "=== Starting relay via vsock ${VSOCK_ADDR} ==="
        PERFETTO_RELAY_SOCK_NAME="${VSOCK_ADDR}" /bin/traced_relay &
        RELAY_PID=$!
        sleep 3
        if kill -0 "$RELAY_PID" 2>/dev/null; then
            log "RELAY_ALIVE pid=$RELAY_PID (vsock)"
            RELAY_TRANSPORT="vsock"
        else
            log "vsock relay failed, falling back to TCP"
            VSOCK_AVAIL=0
        fi
    fi
    if [ "$VSOCK_AVAIL" = "0" ] && [ "$NET_FOUND" = "1" ]; then
        log "=== Starting relay via TCP ${HV_HOST_IP}:${RELAY_PORT} ==="
        PERFETTO_RELAY_SOCK_NAME="${HV_HOST_IP}:${RELAY_PORT}" /bin/traced_relay &
        RELAY_PID=$!
        sleep 3
        if kill -0 "$RELAY_PID" 2>/dev/null; then
            log "RELAY_ALIVE pid=$RELAY_PID (TCP)"
            RELAY_TRANSPORT="tcp"
        else
            log "RELAY_DIED"
            RELAY_MODE=0
        fi
    fi
fi

/bin/traced_probes &
PROBES_PID=$!
sleep 2

# === WORKLOAD: in-process CPU/memory work, minimal fork/exec ===
log "=== Starting low-churn workloads ==="

# Workload 1: Pure CPU - shell arithmetic (no external commands)
cpu_arith() {
    while true; do
        A=0; B=1; i=0
        while [ $i -lt 500 ]; do
            C=$((A + B)); A=$B; B=$C
            i=$((i + 1))
        done
        : # no-op, just loop
    done
}

# Workload 2: Memory/string work - shell variable manipulation
mem_work() {
    while true; do
        STR="a"
        i=0
        while [ $i -lt 100 ]; do
            STR="${STR}${STR}"
            i=$((i + 1))
            if [ ${#STR} -gt 10000 ]; then
                STR="a"
            fi
        done
        sleep 1
    done
}

# Workload 3: File I/O using shell builtins (read, not cat)
io_builtin() {
    while true; do
        while IFS= read -r line; do
            : # discard
        done < /proc/meminfo
        while IFS= read -r line; do
            : # discard
        done < /proc/stat
        sleep 2
    done
}

# Workload 4: Periodic network ping (one process every 5s)
net_slow() {
    while true; do
        ping -c 1 -W 1 "$HV_HOST_IP" > /dev/null 2>&1
        sleep 5
    done
}

# Workload 5: Periodic moderate I/O (one dd every 10s)
io_periodic() {
    while true; do
        dd if=/dev/zero of=/tmp/junk bs=4096 count=64 2>/dev/null
        rm -f /tmp/junk
        sleep 10
    done
}

cpu_arith &
WL1=$!
mem_work &
WL2=$!
io_builtin &
WL3=$!
net_slow &
WL4=$!
io_periodic &
WL5=$!
log "Workloads started: cpu=$WL1 mem=$WL2 io_builtin=$WL3 net=$WL4 io_periodic=$WL5"

if [ "$RELAY_MODE" = "1" ]; then
    log "=== Relay mode: waiting for host to trigger trace (600s) ==="
    log "HV host can trigger multi-VM trace now"
    log "Transport: ${RELAY_TRANSPORT:-none}"
    sleep 600
    log "Relay window closed"
fi

# Cleanup
kill $WL1 $WL2 $WL3 $WL4 $WL5 $PROBES_PID $RELAY_PID 2>/dev/null
log "=== Linux Guest v9 Done ==="
sync
echo o > /proc/sysrq-trigger
sleep 5
