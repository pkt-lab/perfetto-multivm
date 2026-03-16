# Linux ARM64 QVM Guest Tracing

Boot a Linux ARM64 guest inside QNX Hypervisor (QVM), capture a Perfetto trace,
and write it back to the host via **virtio-blk** — no network required.

## Architecture

```
AMD x86_64 host
└── QEMU (aarch64)
    └── QNX Hypervisor 8.0 (QVM host)
        ├── QNX guest (existing workload)
        └── Linux 6.1 ARM64 guest  ← new
            ├── traced
            ├── traced_probes  (linux.ftrace, linux.process_stats)
            └── /dev/vda (virtio-blk) → linux-trace.img on QNX HV
```

The Linux guest captures ftrace events (sched_switch, sched_wakeup, etc.) and
writes the resulting `.pftrace` to a virtio-blk block device backed by a file
on the QNX HV filesystem. The AMD host can then extract the file via SCP.

## Prerequisites

- Debian arm64 kernel image (`Image`, Linux 6.1.0-42-arm64)
- Debian arm64 base initrd (`initrd.gz` from the same kernel package)
- Perfetto binaries for aarch64 (`traced`, `traced_probes`, `perfetto`)
  — static or dynamically linked against the **same** glibc as the initrd
- `virtio_blk.ko` from the matching kernel modules package

## Build the initramfs

```bash
# 1. Unpack the Debian initrd
mkdir /tmp/initrd-work
cd /tmp/initrd-work
zcat /path/to/initrd.gz | cpio -id

# 2. Add Perfetto binaries
cp /path/to/traced        bin/
cp /path/to/traced_probes bin/
cp /path/to/perfetto      bin/
chmod +x bin/traced bin/traced_probes bin/perfetto

# 3. Add virtio_blk.ko (must match kernel version)
mkdir -p lib/modules/6.1.0-42-arm64/kernel/drivers/block
cp /path/to/virtio_blk.ko lib/modules/6.1.0-42-arm64/kernel/drivers/block/

# 4. Install the init script
cp /path/to/guest-init.sh init
chmod 755 init

# 5. Repack
find . | cpio -o -H newc | gzip -1 > /tmp/initrd-linux-qvm.gz
```

See [`scripts/linux-qvm/build-initrd.sh`](../../scripts/linux-qvm/build-initrd.sh) for the full script.

## QVM Configuration

```
system linux-guest
ram 0x80000000,512m
cpu
cpu
guest load /dev/shmem/linux-Image
initrd load /dev/shmem/initrd-linux-qvm.gz
cmdline "console=ttyAMA0 earlycon=pl011,0x1c090000 loglevel=8 init=/init"

vdev vdev-pl011
  loc 0x1c090000
  intr gic:37
  hostdev >/data/linux-console.log

vdev virtio-blk
  loc 0x1c0c0000
  intr gic:40
  hostdev /data/linux-trace.img
  name trace-disk
```

**Notes:**
- Use `/dev/shmem/` for large files (Image: 31MB, initrd: 44MB) to avoid
  filling the QNX HV `/data/` filesystem (61MB total)
- Create the trace image first: `dd if=/dev/zero of=/data/linux-trace.img bs=1M count=16`
- The virtio-blk device appears as `/dev/vda` in the Linux guest

## Boot & Capture

```bash
# On QNX HV
qvm @/data/linux-guest.conf > /data/linux-qvm.log 2>&1 &
# Wait ~20-25 seconds for boot + 10s trace
tail -f /data/linux-console.log
```

The init script runs automatically:
1. Loads `virtio_mmio` + `virtio_blk` kernel modules
2. Starts `traced` and `traced_probes`
3. Runs `perfetto` for 10 seconds (ftrace + process stats)
4. Writes trace to `/dev/vda` with an 8-byte size header at offset 0, data at offset 512
5. Powers off the guest

## Extract Trace

```bash
# From AMD host
sshpass -p root scp -P 2240 root@localhost:/data/linux-trace.img /tmp/

# Parse the header and extract
TRACE_SIZE=$(dd if=/tmp/linux-trace.img bs=8 count=1 2>/dev/null | tr -d "\0")
dd if=/tmp/linux-trace.img of=trace.pftrace bs=512 skip=1 \
   count=$(( (TRACE_SIZE + 511) / 512 )) 2>/dev/null
truncate -s $TRACE_SIZE trace.pftrace

# Validate
python3 -c "
data=open('trace.pftrace','rb').read()
assert data[0]==0x0a,'Not a Perfetto trace'
print(f'OK: {len(data)} bytes')
"
```

## Verified Results

| Item | Value |
|---|---|
| Kernel | Linux 6.1.0-42-arm64 (Debian) |
| Boot time | ~4 seconds |
| Trace duration | 10 seconds |
| Trace size | ~17KB |
| TracePackets | 72 |
| Data sources | linux.ftrace (sched_switch, sched_wakeup), linux.process_stats |
| Block device | `/dev/vda` (virtio-mmio at 0x1c0c0000) |

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Syntax error: "(" unexpected` | Wrong arch binary | Check `file binary` — must be aarch64 |
| `virtio0` in sysfs but no `/dev/vda` | `virtio_blk.ko` not loaded | Add `insmod virtio_blk.ko` to init |
| `undefined symbol: __tunable_is_initialized` | glibc version mismatch | Use Perfetto binaries from the same glibc as the initrd |
| `/data/` full | Image + initrd too large | Use `/dev/shmem/` for large files |
| trace size 0 on disk | No block device at write time | Load virtio modules **before** starting traced |
