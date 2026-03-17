# QNX 8.0 HV Inter-VM Networking: vdevpeer-net Setup

## Overview

Guest-to-host IP connectivity via `vdev-virtio-net` + `mods-vdevpeer-net.so`.
This creates a point-to-point virtual network link between the HV host's io-sock
and the guest's virtio-net interface.

## What's Available on the HV Host

Already present in `/system/lib/dll/`:
- `vdev-virtio-net.so` — virtio-net vdev for qvm guests
- `mods-vdevpeer-net.so` — io-sock driver for host-side vdevpeer networking
- `vdev-shmem.so` — shared memory vdev (alternative approach)

Already present in `/system/bin/`:
- `io-sock` — networking manager (already running with `-m phy -m fdt -d vtnet_mmio`)
- `ifconfig` — interface configuration
- `vpctl` — vdevpeer interface configuration utility
- `qvm` — virtual machine manager
- `route` — routing table management

Current host interfaces:
- `vtnet0` — 10.0.2.15/24 (QEMU user-mode network, SSH port 2241)
- `lo0` — 127.0.0.1

## Architecture

```
QEMU (10.0.2.2 gateway)
  |
  vtnet0 (10.0.2.15) — HV Host io-sock
  |
  vp0 (192.168.100.1) — HV Host vdevpeer interface
  |  (vdevpeer-net point-to-point link)
  |
  vtnet0 (192.168.100.2) — QNX Guest virtio-net
```

## Step-by-Step Setup

### Step 1: Add virtio-net vdev to guest qvm config

Current guest config (`/dev/shmem/qnx-guest.conf`):
```
system qnx-guest
ram 0x80000000,512m
cpu
guest load /dev/shmem/qnx-guest-ifs.bin

vdev vdev-pl011
  loc 0x1c090000
  intr gic:37
  hostdev >/dev/shmem/qnx-guest-console.log
```

Add a `vdev-virtio-net` block with `peer` and `name` options:
```
system qnx-guest
ram 0x80000000,512m
cpu
guest load /dev/shmem/qnx-guest-ifs.bin

vdev vdev-pl011
  loc 0x1c090000
  intr gic:37
  hostdev >/dev/shmem/qnx-guest-console.log

vdev vdev-virtio-net
  peer /dev/qvm/qnx-guest/vp0
  name /dev/qvm/qnx-guest/vp0
  loc 0x1c0b0000
  intr gic:39
```

Key vdev-virtio-net options (from binary strings analysis):
- `peer <peer_name>` — **mandatory** — host peer-to-peer path for I/O
- `name <name>` — this side's name in the peer-to-peer connection
- `loc <addr>` — MMIO address (pick unused ARM FM address)
- `intr gic:<n>` — GIC interrupt (pick unused SPI)
- `mac <mac_addr>` — optional MAC address override
- `peerfeats <num>` — optional feature bits for peer protocol

### Step 2: Load vdevpeer-net module into host io-sock

The host io-sock is already running. Mount the vdevpeer-net module dynamically:

```bash
# Mount the vdevpeer-net driver into the running io-sock
/system/bin/mount -T io-sock vdevpeer-net
```

Or, for a fresh io-sock start that includes vdevpeer-net:
```bash
/system/bin/io-sock -m phy -m fdt -m vdevpeer-net -d vtnet_mmio
```

### Step 3: Create and configure the vp0 interface on the host

After qvm starts the guest (which creates `/dev/qvm/qnx-guest/vp0`):

```bash
# Create the vdevpeer interface
/system/bin/ifconfig vp0 create

# Configure vpctl to connect to the guest's vdev
/system/bin/vpctl vp0 peer=/dev/qvm/qnx-guest/vp0

# Assign IP address to the host side
/system/bin/ifconfig vp0 inet 192.168.100.1/24 up
```

### Step 4: Configure networking in the guest IFS

The guest needs:
1. `devs-vtnet_mmio.so` driver (for virtio-net MMIO transport)
2. `io-sock` with appropriate drivers
3. Static IP configuration (no DHCP server on this link)

Guest IFS must include virtio-net networking setup in its startup script:
```
# In guest IFS [+script] section:
io-sock -m phy -m fdt -d vtnet_mmio &
waitfor /dev/socket
if_up -p vtnet0
ifconfig vtnet0 inet 192.168.100.2/24 up
route add default 192.168.100.1
```

### Step 5: Test connectivity

From HV host:
```bash
/system/bin/ping 192.168.100.2
```

### Step 6: Enable traced_relay forwarding

On HV host (already verified working):
```bash
/data/traced --enable-relay-endpoint &
/data/traced_qnx_probes &
```

On guest (once networking works):
```bash
# Guest connects to host's traced relay endpoint via TCP
PERFETTO_PRODUCER_SOCK_NAME=192.168.100.1:21101 /data/traced_relay &
```

Or if Unix sockets over vdevpeer are preferred, use the relay architecture
already verified on the host with Unix domain sockets.

## Alternative: vdev-shmem for Trace Data

If virtio-net proves problematic, `vdev-shmem.so` provides a shared memory
region accessible from both host and guest. Trace data could be written to
shared memory by the guest and read by the host, avoiding networking entirely.

```
vdev vdev-shmem
  loc 0x1c0e0000
  intr gic:42
  hostdev /dev/shmem/trace-shared
```

This is lower-level but avoids the full networking stack.

## Guest IFS Rebuild Required

The current guest IFS (v38) likely does not include networking drivers.
A new guest IFS must be built on AMD with:
- `devs-vtnet_mmio.so` and associated network DLLs
- `io-sock` binary
- `ifconfig`, `if_up`, `route` utilities
- Network startup commands in the `[+script]` block

Build on AMD (10.248.88.38):
```bash
cd /tmp/qnx-arm-hyp
source /home/amd/qnx800/qnxsdp-env.sh
mkifs -v /tmp/qnx-guest-ifs-net.build /tmp/qnx-guest-ifs-net.bin
```

## Address/Interrupt Allocation

| Resource | Address | Interrupt | Used By |
|----------|---------|-----------|---------|
| PL011 UART | 0x1c090000 | gic:37 | Guest serial console |
| virtio-blk | 0x1c0c0000 | gic:40 | Linux guest disk (if used) |
| virtio-blk | 0x1c0d0000 | gic:41 | QNX guest disk (optional) |
| **virtio-net** | **0x1c0b0000** | **gic:39** | **Guest vdevpeer networking** |
