#!/bin/sh
# guest-init.sh — Linux ARM64 QVM guest init script
# Runs as PID 1 inside the initramfs.
# Captures a Perfetto trace and writes it to virtio-blk (/dev/vda).
#
# Layout on /dev/vda:
#   offset 0     : 8-byte ASCII decimal trace size (zero-padded)
#   offset 512   : raw .pftrace data

export PATH=/bin:/sbin:/usr/bin:/usr/sbin
export LD_LIBRARY_PATH=/lib:/lib/aarch64-linux-gnu

echo "=== Linux Guest Boot ==="
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
mount -t tmpfs tmpfs /tmp
mount -t tmpfs tmpfs /run
mount -t tracefs tracefs /sys/kernel/tracing 2>/dev/null
mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null

echo "=== Loading virtio modules ==="
insmod /lib/modules/6.1.0-42-arm64/kernel/drivers/virtio/virtio_mmio.ko 2>/dev/null
echo "virtio_mmio: $?"
insmod /lib/modules/6.1.0-42-arm64/kernel/drivers/block/virtio_blk.ko 2>/dev/null
echo "virtio_blk: $?"
sleep 2

echo "=== Block devices ==="
ls -la /dev/vd* 2>/dev/null || echo "no /dev/vd*"

echo "=== Starting Perfetto ==="
/bin/traced &
sleep 2
/bin/traced_probes &
sleep 2

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

echo "=== Capturing 10s trace ==="
/bin/perfetto --txt -c /tmp/perfetto.cfg -o /tmp/trace.pftrace
RC=$?
echo "PERFETTO_DONE=$RC"

if [ -f /tmp/trace.pftrace ]; then
  TRACE_SIZE=$(wc -c < /tmp/trace.pftrace)
  echo "TRACE_SIZE=$TRACE_SIZE"
else
  TRACE_SIZE=0
  echo "NO_TRACE_FILE"
fi

echo "=== Writing trace to virtio-blk ==="
SAVED=0
for DEV in /dev/vda /dev/vdb /dev/sda /dev/sdb; do
  if [ -b "$DEV" ]; then
    echo "Writing ${TRACE_SIZE} bytes to $DEV"
    # 8-byte header: ASCII decimal size at offset 0
    printf "%08d" "$TRACE_SIZE" | dd of="$DEV" bs=8 count=1 2>/dev/null
    # trace data at offset 512 (sector 1)
    dd if=/tmp/trace.pftrace of="$DEV" bs=512 seek=1 2>/dev/null
    echo "TRACE_SAVED_TO=$DEV"
    SAVED=1
    break
  fi
done
[ "$SAVED" = "0" ] && echo "NO_BLOCK_DEVICE"

echo "=== Done ==="
sync
echo o > /proc/sysrq-trigger
sleep 5
