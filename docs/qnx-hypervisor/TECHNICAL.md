# QNX 8.0 Hypervisor — Technical Deep Dive

> **LICENSE WARNING**: QNX SDP 8.0 is **PROPRIETARY SOFTWARE** owned by BlackBerry QNX.
> This document contains **NO** QNX source code or binaries.
> The ARM64 trampoline assembly is original work, not derived from QNX.

---

## 1. The ARM64 Image Trampoline Problem

### Root Cause

QEMU's `-kernel` option supports two ARM64 binary formats:
1. **Linux ARM64 Image** — flat binary with a 64-byte header containing magic `0x644d5241` ("ARMd" in LE) at offset 56
2. **ELF** — standard ELF binary

When QEMU loads a Linux ARM64 Image, it:
- Reads `text_offset` from offset 8 to determine load address
- Loads the image at `RAM_BASE + text_offset`
- Sets `X0 = DTB address` (device tree blob, placed at `0x40000000` for virt machine)
- Jumps to the entry point

When QEMU loads an ELF, it:
- Loads segments per ELF program headers
- Sets `X0 = 0` (no DTB passed)
- Jumps to the ELF entry point

QNX IFS is an ELF binary. The QNX startup code (`startup-qemu-virt`) expects X0 to contain the DTB address. With X0=0, the FDT parsing code fails silently and the boot hangs — no serial output, no crash, just an infinite loop.

### Solution: 128-Byte Trampoline

We create a minimal ARM64 Image file that:
1. Has the correct Linux ARM64 Image header (magic at offset 56)
2. Contains ARM64 instructions that set X0 to the DTB address and jump to the QNX ELF entry
3. Is loaded via `-kernel` (as ARM64 Image), while the real QNX IFS is loaded via `-device loader` (as ELF)

### Trampoline Layout

```
Offset  Size  Content                          Purpose
------  ----  -------                          -------
0x00    4     Branch instruction (B +4)        ARM64 Image: code0
0x04    4     NOP                              ARM64 Image: code1
0x08    8     0x0000000000200000               text_offset → load at 0x40200000
0x10    8     image_size (small)               ARM64 Image: image_size
0x18    8     flags                            ARM64 Image: flags
0x20    32    reserved (zeros)                 ARM64 Image: reserved
0x38    4     0x644d5241                       ARM64 Image: magic ("ARMd" LE)
0x3C    4     0x00000000                       ARM64 Image: PE offset (0 = not PE)
0x40    ...   Trampoline code:                 Our payload
              MOV X0, #0x40000000              Set X0 = DTB address
              LDR X1, =0x80000da8              QNX ELF entry point
              BR X1                            Jump to QNX
```

### Key Addresses

| Address | What | Why |
|---------|------|-----|
| `0x40000000` | DTB (Device Tree Blob) | QEMU virt places DTB here by default |
| `0x40200000` | Trampoline load address | `0x40000000 + text_offset(0x200000)` |
| `0x80000000` | QNX IFS load address | ELF program header specifies this |
| `0x80000da8` | QNX ELF entry point | From `readelf -h` on the QNX IFS binary |

### Why Not Just Patch QEMU?

You could patch QEMU to pass X0=DTB for ELF kernels, but:
- Requires custom QEMU build
- Breaks Linux ELF boot protocol
- Trampoline is portable and works with stock QEMU

### Why Not Use U-Boot?

U-Boot could load the QNX ELF and pass DTB, but:
- Adds complexity (need U-Boot binary, boot scripts)
- Trampoline is simpler (128 bytes vs entire bootloader)
- No extra boot stage latency

---

## 2. BSP Mismatch: ARM Foundation Model vs QEMU Virt

### The Problem

`mkqnximage --type=qemu` generates configuration for the ARM Foundation Model (ARM FM), not QEMU's `virt` machine. These are different virtual platforms:

| Feature | ARM Foundation Model | QEMU virt |
|---------|---------------------|-----------|
| Startup binary | `startup-armv8_fm` | `startup-qemu-virt` |
| UART | PL011 at `0x1c090000` | PL011 at `0x09000000` |
| virtio MMIO | `0xa000000` range | `0xa000000` range |
| GIC | GICv3 | GICv2/v3 (configurable) |
| Machine type | Fixed | `virt-4.2` (versioned) |

### What Must Change for QEMU Virt

1. **Startup binary**: `startup-armv8_fm` → `startup-qemu-virt` (for the host only)
2. **smem addresses for virtio**: Must match QEMU virt's MMIO layout
3. **IRQ numbers**: Must match QEMU virt's GIC SPI mapping

### Why the Guest Uses ARM FM Config

The qvm hypervisor presents a **virtual** hardware platform to the guest. When using `vdev-pl011`, `vdev-virtio-blk`, etc., qvm emulates ARM Foundation Model-style hardware. So the guest legitimately uses `startup-armv8_fm` and ARM FM addresses.

---

## 3. MMIO Address Map

### QEMU Virt (Hypervisor Host)

These are the physical addresses seen by the hypervisor host OS:

```
0x00000000 - 0x3FFFFFFF   Flash, GIC, UART, RTC, etc.
0x09000000                 PL011 UART (QEMU virt)
0x0a000000 - 0x0a000200   virtio MMIO region (multiple devices)
  0x0a003e00               virtio-blk #0 (host disk), IRQ 79
  0x0a003c00               virtio-blk #1 (guest disk), IRQ 78
  0x0a003a00               virtio-net, IRQ 77
0x40000000                 RAM base (2 GB)
0x40000000                 DTB (placed by QEMU)
0x80000000                 QNX IFS load address
```

### ARM Foundation Model (qvm Guest Virtual Addresses)

These are the virtual addresses presented by qvm to the guest:

```
0x1c090000                 PL011 UART (vdev-pl011), GIC IRQ 37
0x1c0b0000                 virtio-net (vdev-virtio-net, TBD), GIC IRQ 43
0x1c0d0000                 virtio-blk (vdev-virtio-blk), GIC IRQ 41
0x20000000                 virtio-console (vdev-virtio-console), GIC IRQ 42
0x80000000                 Guest RAM base (512 MB)
```

---

## 4. Dual Disk Architecture

```
QEMU                          QNX Hypervisor Host           qvm Guest
─────                         ──────────────────           ─────────
virtio-blk drv0 ──────────→  /dev/hd0 (host rootfs)
  (qnx-hypF-disk.img)          Contains:
                                 /data/guest.conf
                                 /data/qnx-guest-ifs.bin

virtio-blk drv1 ──────────→  /dev/hd1 (guest disk)  ───→  /dev/hd0 (guest rootfs)
  (qnx-guest-disk.img)         Passed through via            (seen by guest OS)
                                vdev-virtio-blk
```

The hypervisor host must have **two** `devb-virtio` driver instances:
- First: `smem=0xa003e00,irq=79` → `/dev/hd0`
- Second: `smem=0xa003c00,irq=78` → `/dev/hd1`

Without the second driver, `/dev/hd1` doesn't exist and qvm can't pass the guest disk through.

---

## 5. EL2 (Hypervisor Exception Level)

### Requirements

- QEMU must be started with `virtualization=on` in the machine options
- This enables EL2 (Exception Level 2) in the emulated CPU
- QNX startup with `-H` flag boots at EL2 and initializes the hypervisor
- Without `virtualization=on`, the CPU has no EL2 and qvm cannot function

### QEMU TCG vs KVM

- **TCG** (Tiny Code Generator): Full software emulation. Slower but works on any host architecture (including x86_64). Supports `virtualization=on` for emulated EL2.
- **KVM**: Hardware-accelerated. Requires ARM64 host with VHE. More complex nested virtualization considerations.

This guide uses TCG mode exclusively.

---

## 6. GIC (Generic Interrupt Controller) Notes

QEMU virt supports GICv2 and GICv3. We use `gic-version=3`:
- QNX hypervisor requires GICv3 for proper virtual interrupt injection
- GICv3 supports more SPIs (Shared Peripheral Interrupts) needed for virtio devices
- The guest sees a virtualized GIC managed by qvm

---

## 7. Common Gotchas

### Gotcha 1: Silent Boot Hang (No Serial Output)

**Symptom**: QEMU starts, no output in serial log, CPU at 100%.
**Cause**: DTB not passed (X0=0). QNX startup tries to parse DTB at address 0, fails, loops.
**Fix**: Use the ARM64 Image trampoline.

### Gotcha 2: Wrong Startup Binary

**Symptom**: Kernel panic or immediate crash after startup banner.
**Cause**: `startup-armv8_fm` expects ARM FM hardware layout; QEMU virt has different MMIO.
**Fix**: Use `startup-qemu-virt` for the hypervisor host IFS.

### Gotcha 3: Guest IFS Not Found

**Symptom**: `qvm` starts but guest fails with "cannot load" error.
**Cause**: Guest IFS binary not on the hypervisor host's filesystem.
**Fix**: Ensure `/data/qnx-guest-ifs.bin` exists on the host disk image (drv0).

### Gotcha 4: IRQ Conflicts

**Symptom**: Driver fails to attach or device not responding.
**Cause**: IRQ number mismatch between virtio device and driver configuration.
**Fix**: Verify IRQ numbers match QEMU's virtio MMIO mapping. Use `qemu-system-aarch64 -machine virt,dumpdtb=virt.dtb` and `dtc -I dtb -O dts virt.dtb` to inspect the actual device tree.

### Gotcha 5: text_offset Collision

**Symptom**: Trampoline or QNX IFS corrupted at boot.
**Cause**: Trampoline's text_offset places it in the same memory range as the QNX IFS.
**Fix**: Ensure `text_offset` in the trampoline header places the trampoline below `0x80000000` (e.g., `0x200000` → loads at `0x40200000`).

### Gotcha 6: Machine Version Matters

**Symptom**: Unexpected hardware differences, missing devices.
**Cause**: Different QEMU virt machine versions have different defaults.
**Fix**: Pin to `virt-4.2` for reproducibility. This version's MMIO layout is well-tested with this configuration.

---

## 8. Entry Point Discovery

To find the QNX IFS ELF entry point (needed for trampoline):

```bash
# On the build machine with QNX cross-tools:
readelf -h /tmp/qnx-hyp-final.bin | grep "Entry point"
# Example output: Entry point address: 0x80000da8

# Or with any aarch64 readelf:
aarch64-linux-gnu-readelf -h /tmp/qnx-hyp-final.bin
```

The entry point (`0x80000da8` in our case) must be hardcoded in the trampoline's branch target.

---

## 9. Future Work

- **Guest networking**: Add `vdev-virtio-net` at `0x1c0b0000`, IRQ 43 to enable guest network access
- **Multiple guests**: qvm supports multiple concurrent VMs — add more guest configs
- **KVM acceleration**: Test on ARM64 host with KVM for near-native performance
- **Automated testing**: CI pipeline that builds and boots the full stack, verifies SSH connectivity
