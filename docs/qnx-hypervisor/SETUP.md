# QNX 8.0 Hypervisor on QEMU — Reproduction Guide

> **LICENSE WARNING**: QNX SDP 8.0 is **proprietary software** owned by BlackBerry QNX.
> You **must** have a valid QNX license. This guide references QNX tools and packages
> but does **not** include any QNX binaries, libraries, source code, or disk images.

## Prerequisites

### Build Machine (x86_64 Linux)

- QNX SDP 8.0 installed (e.g., at `$HOME/qnx800/`)
- QNX SDP packages installed:
  - `com.qnx.qnx800.target.qemuvirt` — QEMU virt BSP
  - `com.qnx.qnx800.target.hypervisor.core` — qvm binary
  - `com.qnx.qnx800.target.hypervisor.libhyp` — hypervisor library
  - `com.qnx.qnx800.target.driver.virtio` — virtio drivers

### Runtime Machine

- `qemu-system-aarch64` (TCG mode — no KVM needed on x86_64; KVM works on ARM64)
- `sshpass` for scripted SSH access
- At least 4 GB free RAM

---

## Quick Start (Automated)

```bash
# Source QNX SDP environment
source $HOME/qnx800/qnxsdp-env.sh

# Build + boot in one command
./scripts/build-and-boot-hyp.sh /tmp/qnx-hyp-build

# SSH in (default password: root)
sshpass -p root ssh -p 2240 root@localhost
```

## Step-by-Step

### Step 1: Generate Base Image

```bash
source $HOME/qnx800/qnxsdp-env.sh

WORKDIR=/tmp/qnx-hyp-build
mkdir -p "$WORKDIR" && cd "$WORKDIR"

# Generate hypervisor host image
mkqnximage --arch=aarch64le --type=qvm --qvm=yes --clean --build
```

This creates `output/build/ifs.build` and `output/build/startup.sh`.
The generated image uses `startup-armv8_fm` — **wrong for QEMU virt**.

### Step 2: Fix Build Files

Two changes are needed:

#### 2a. Fix startup binary in ifs.build

```bash
# Replace ARM Foundation Model startup with QEMU virt startup
sed -i 's/startup-armv8_fm -H/startup-qemu-virt -H/' output/build/ifs.build
```

Why: `startup-armv8_fm` uses ARM Foundation Model MMIO addresses.
`startup-qemu-virt` uses QEMU virt MMIO addresses. Both support `-H` (hypervisor/EL2 mode).

#### 2b. Fix virtio device addresses in startup.sh

```bash
# Fix devb-virtio MMIO address (ARM FM → QEMU virt)
sed -i 's/smem=0x1c0d0000,irq=41/smem=0x0a003e00,irq=79/' output/build/startup.sh

# Disable devc-virtio console (uses ARM FM MMIO, causes Bus Error on QEMU virt)
sed -i 's|^ *devc-virtio -e 0x[0-9a-f]*,[0-9]*|# devc-virtio disabled for QEMU virt|' output/build/startup.sh
```

QEMU virt virtio MMIO addresses (from device tree):
| Device | MMIO Base | IRQ | Notes |
|--------|-----------|-----|-------|
| virtio-blk (1st) | `0x0a003e00` | 79 | Hypervisor root disk |
| virtio-blk (2nd) | `0x0a003c00` | 78 | Guest disk (optional) |
| virtio-net | auto (FDT) | auto | Handled by io-sock |

### Step 3: Rebuild the IFS

```bash
cd "$WORKDIR"
mkifs output/build/ifs.build output/ifs-rebuilt.bin
```

Verify:
```bash
readelf -h output/ifs-rebuilt.bin | grep Entry
# Expected: 0x80000da8
```

### Step 4: Build the Trampoline

The trampoline is needed because QEMU only passes DTB address (X0) for Linux ARM64 Image format,
not for ELF. QNX IFS is ELF. See [TECHNICAL.md](TECHNICAL.md) for details.

```bash
python3 trampoline/build-trampoline.py --entry 0x80000da8 --dtb 0x40000000 \
  -o /tmp/qnx-tramp-hyp.img
```

### Step 5: Boot with QEMU

```bash
qemu-system-aarch64 \
  -machine virt-4.2,virtualization=on,gic-version=3 \
  -cpu cortex-a57 -smp 2 -m 2G \
  -kernel /tmp/qnx-tramp-hyp.img \
  -device loader,file=$WORKDIR/output/ifs-rebuilt.bin \
  -drive file=$WORKDIR/output/disk-qvm,format=raw,if=none,id=drv0,snapshot=on \
  -device virtio-blk-device,drive=drv0 \
  -device virtio-net-device,netdev=net0 \
  -netdev user,id=net0,hostfwd=tcp::2240-:22 \
  -object rng-random,filename=/dev/urandom,id=rng0 \
  -device virtio-rng-device,rng=rng0 \
  -serial file:/tmp/qnx-hyp.log \
  -display none -daemonize
```

Notes:
- `snapshot=on` protects the original disk image from writes
- Remove `snapshot=on` if you need persistent changes (e.g., writing guest files to /data/)
- Port 2240 is forwarded to guest SSH (port 22)

### Step 6: Verify

```bash
# Check serial log
cat /tmp/qnx-hyp.log
# Should show: "Startup complete" and "QNX ... QEMU_virt aarch64le"

# SSH in
sshpass -p root ssh -p 2240 -o StrictHostKeyChecking=no root@localhost

# Inside QNX:
uname -a           # QNX noname 8.0.0 ... QEMU_virt aarch64le
pidin info         # FreeMem: ~1800MB, 2x Cortex-A57
ls /system/bin/qvm # Hypervisor binary present
```

---

## Expected Serial Output

```
** CPU 0 PE is not awake
** CPU 1 PE is not awake
---> Starting slogger2
---> Starting PCI Services
---> Starting fsevmgr
---> Starting devb
---> Mounting file systems
Path=0 - target=0 lun=0  Direct-Access(0) - VIRTIO Rev:
---> Mounting file systems
---> Starting Networking
---> Starting sshd
---> Starting misc
Process count:19
Startup complete
QNX noname 8.0.0 2025/07/30-19:17:34EDT QEMU_virt aarch64le
```

## Adding a Second Disk (for QVM Guest)

To run a QVM guest, add a second virtio-blk device:

```bash
# Add to startup.sh before rebuilding IFS:
devb-virtio blk smem=0xa003c00,irq=78
waitfor /dev/hd1 1000

# Add to QEMU command line:
-drive file=/tmp/qnx-guest-disk.img,format=raw,if=none,id=drv1 \
-device virtio-blk-device,drive=drv1
```

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Serial log empty (0 bytes) | Wrong startup binary or trampoline | Use `startup-qemu-virt`, verify trampoline entry matches IFS |
| `Bus error` on boot | `devc-virtio` using ARM FM MMIO address | Disable or fix `devc-virtio` address |
| `No virtio interfaces found` | Wrong `smem` address for devb-virtio | Use `0x0a003e00,irq=79` for QEMU virt |
| `network stack down: Bad file descriptor` | io-sock initialization race | Ensure `pipe`, `random`, `devc-pty` start before io-sock |
| SSH timeout | Network not configured or host key mismatch | Check `ifconfig vtnet0`, clear known_hosts |
| `if_up: network stack down` | Missing pipe/random/pty services | Ensure startup.sh initializes them before io-sock |
| Trampoline loads but hangs | Entry point mismatch | `readelf -h ifs.bin` must match trampoline jump target |
