# QNX 8.0 Hypervisor — Step-by-Step Reproduction Guide

> **LICENSE WARNING**: QNX SDP 8.0 is **PROPRIETARY SOFTWARE** owned by BlackBerry QNX.
> You **MUST** have a valid QNX license. This guide references QNX tools and packages
> but does **NOT** include any QNX binaries, libraries, source code, or disk images.

## Prerequisites

### Build Machine (AMD x86_64)

- QNX SDP 8.0 installed (e.g., at `/home/amd/qnx800/`)
- The following QNX SDP packages installed:
  - `com.qnx.qnx800.target.qemuvirt` — QEMU virt BSP
  - `com.qnx.qnx800.target.hypervisor.core` — qvm binary
  - `com.qnx.qnx800.target.hypervisor.extras` — hypervisor extras
  - `com.qnx.qnx800.target.hypervisor.group` — hypervisor group package
  - `com.qnx.qnx800.target.driver.virtio` — virtio drivers (devb-virtio, devc-virtio)

### Runtime Machine

- Any machine with `qemu-system-aarch64` (TCG mode — no KVM needed)
- ARM64 native host recommended but x86_64 works (slower via full TCG emulation)
- At least 4 GB free RAM (2 GB for QEMU guest + overhead)

---

## Step 1: Set Up Build Environment

```bash
# Source the QNX SDP environment
source /home/amd/qnx800/qnxsdp-env.sh

# Verify tools are available
which mkqnximage   # should resolve
which mkifs        # should resolve
```

## Step 2: Build the Hypervisor Host IFS

```bash
WORKDIR=/tmp/qnx-arm-hyp2
mkdir -p "$WORKDIR"
cd "$WORKDIR"

# Generate the hypervisor host image
mkqnximage --arch=aarch64le --type=qemu --qvm=yes --output="$WORKDIR/hyp-host"
```

This generates an IFS build file and supporting files. The generated image will use `startup-armv8_fm` by default — this is **wrong** for QEMU virt and must be fixed.

## Step 3: Fix the Host IFS Build File

Edit the generated `ifs.build` (or equivalent build spec) with these changes:

### 3a. Fix startup binary

Replace:
```
startup-armv8_fm -H
```
With:
```
startup-qemu-virt -H
```

The `-H` flag enables hypervisor mode (EL2).

### 3b. Fix smem (shared memory) addresses

The ARM Foundation Model uses different MMIO addresses than QEMU virt. Update:

Replace ARM FM smem addresses with QEMU virt addresses:
```
# Primary virtio-blk (hypervisor host disk)
smem=0xa003e00,irq=79

# Secondary virtio-blk (guest disk — add this line)
smem=0xa003c00,irq=78
```

### 3c. Add second virtio-blk driver

Add a second `devb-virtio` entry for the guest disk:
```
devb-virtio blk smem=0xa003c00,irq=78
```

This allows the hypervisor host to see both:
- `/dev/hd0` — hypervisor host root filesystem
- `/dev/hd1` — guest IFS disk (passed through to qvm guest)

### 3d. Rebuild the IFS

```bash
# Rebuild with corrected build spec
mkifs -v ifs.build /tmp/qnx-hyp-final.bin
```

## Step 4: Build the Guest IFS

```bash
GUEST_DIR=/tmp/qnx-arm-guest
mkdir -p "$GUEST_DIR"
cd "$GUEST_DIR"

# Generate the guest image — type=qvm is correct here
mkqnximage --arch=aarch64le --type=qvm --output="$GUEST_DIR/guest"
```

The guest uses `startup-armv8_fm -H` — this is **correct** because the qvm virtual machine presents an ARM Foundation Model-like hardware interface.

### 4a. Build guest IFS and disk

```bash
mkifs -v ifs.build /tmp/qnx-guest-ifs.bin
```

Create a raw disk image containing the guest IFS:
```bash
# Create a disk image with the guest IFS
dd if=/dev/zero of=/tmp/qnx-guest-disk.img bs=1M count=128
# Write guest IFS to the disk image (details depend on your partitioning scheme)
```

## Step 5: Create the ARM64 Trampoline

See [TECHNICAL.md](TECHNICAL.md) for full details on why this is needed.

The trampoline is a 128-byte ARM64 Image header that:
1. Tricks QEMU into treating the file as a Linux ARM64 kernel (sets X0 = DTB address)
2. Jumps to the actual QNX ELF entry point

```bash
# Assemble the trampoline (see scripts/build-hyp.sh for automation)
# The trampoline binary goes to /tmp/qnx-tramp-hyp.img
```

Key parameters:
- `text_offset` at offset 8: `0x00200000` → QEMU loads trampoline at `0x40200000`
- QNX IFS loaded via `-device loader` at its ELF entry: `0x80000000`
- DTB placed at `0x40000000` (QEMU virt default)
- Trampoline code: sets X0 to DTB address, branches to QNX entry at `0x80000da8`

## Step 6: Create the Hypervisor Host Disk Image

```bash
# Create a raw disk image for the hypervisor host root filesystem
dd if=/dev/zero of=/tmp/qnx-hypF-disk.img bs=1M count=256

# Format and populate with QNX filesystem containing:
#   /data/guest.conf        — qvm guest configuration
#   /data/qnx-guest-ifs.bin — guest IFS binary
```

## Step 7: Boot with QEMU

```bash
# Use the provided boot script:
./scripts/boot-qnx-hyp.sh

# Or run manually:
qemu-system-aarch64 \
  -machine virt-4.2,virtualization=on,gic-version=3 \
  -cpu cortex-a57 -smp 2 -m 2G \
  -kernel /tmp/qnx-tramp-hyp.img \
  -device loader,file=/tmp/qnx-hyp-final.bin \
  -drive file=/tmp/qnx-hypF-disk.img,format=raw,if=none,id=drv0 \
  -device virtio-blk-device,drive=drv0 \
  -drive file=/tmp/qnx-guest-disk.img,format=raw,if=none,id=drv1 \
  -device virtio-blk-device,drive=drv1 \
  -device virtio-net-device,netdev=net0 \
  -netdev user,id=net0,hostfwd=tcp::2238-:22 \
  -object rng-random,filename=/dev/urandom,id=rng0 \
  -device virtio-rng-device,rng=rng0 \
  -serial file:/tmp/qnx-hypF.log -display none \
  -monitor unix:/tmp/qemu-hypF.sock,server,nowait
```

## Step 8: Verify Hypervisor Host Boot

```bash
# Watch the serial log
tail -f /tmp/qnx-hypF.log

# SSH into the hypervisor host
ssh -p 2238 root@localhost

# Verify hypervisor is running
pidin | grep qvm
ls /dev/hd0 /dev/hd1   # both disks visible
```

## Step 9: Start the Guest VM

On the hypervisor host (via SSH):

```bash
# Copy guest config if not already on disk
# (should be at /data/guest.conf from the disk image)

# Start the guest
qvm @/data/guest.conf &

# Watch guest console output
cat /data/guest-console.log
```

## Step 10: Verify Guest

```bash
# On the hypervisor host, check qvm status
pidin | grep qvm

# Guest console output should show QNX boot messages
# Guest has its own virtio-blk (/dev/hd1 passed through as vdev-virtio-blk)
```

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Boot hangs immediately | X0 not set (no DTB) | Trampoline missing or wrong text_offset |
| `startup` crash / no serial output | Wrong startup binary | Use `startup-qemu-virt` not `startup-armv8_fm` for host |
| No `/dev/hd1` | Missing second virtio-blk | Add second `devb-virtio` with `smem=0xa003c00,irq=78` |
| SSH connection refused | Network not up | Check `io-pkt` and `dhclient` in IFS build |
| qvm fails to start guest | Missing guest IFS on disk | Verify `/data/qnx-guest-ifs.bin` exists on hd0 |
| Guest boot hangs | Wrong vdev addresses | Verify guest.conf uses ARM FM addresses (see qvm-guest.conf) |
