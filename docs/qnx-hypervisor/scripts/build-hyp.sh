#!/usr/bin/env bash
# build-hyp.sh — Build QNX 8.0 Hypervisor Host and Guest images
#
# LICENSE WARNING: QNX SDP 8.0 is PROPRIETARY SOFTWARE owned by BlackBerry QNX.
# You MUST have a valid QNX license to run this script.
# This script invokes QNX tools — you must provide your own licensed QNX SDP.
# No QNX binaries, libraries, or source code are included in this repository.
#
# Prerequisites:
#   - QNX SDP 8.0 installed
#   - Required packages: qemuvirt, hypervisor.core, hypervisor.extras,
#     hypervisor.group, driver.virtio
#
# Usage:
#   source /path/to/qnx800/qnxsdp-env.sh
#   ./build-hyp.sh [output_dir]

set -euo pipefail

# --- Configuration ---
QNX_SDP="${QNX_SDP:-$HOME/qnx800}"
OUTPUT_DIR="${1:-/tmp/qnx-arm-hyp-build}"
HOST_IFS_OUT="${OUTPUT_DIR}/qnx-hyp-final.bin"
GUEST_IFS_OUT="${OUTPUT_DIR}/qnx-guest-ifs.bin"
HOST_DISK_OUT="${OUTPUT_DIR}/qnx-hypF-disk.img"
GUEST_DISK_OUT="${OUTPUT_DIR}/qnx-guest-disk.img"
TRAMPOLINE_OUT="${OUTPUT_DIR}/qnx-tramp-hyp.img"

# QNX IFS ELF entry point — update this if your build produces a different entry
QNX_ENTRY_POINT="0x80000da8"

# --- Validation ---
if ! command -v mkqnximage &>/dev/null; then
    echo "ERROR: mkqnximage not found. Source qnxsdp-env.sh first:"
    echo "  source ${QNX_SDP}/qnxsdp-env.sh"
    exit 1
fi

if ! command -v mkifs &>/dev/null; then
    echo "ERROR: mkifs not found. QNX SDP not properly configured."
    exit 1
fi

mkdir -p "${OUTPUT_DIR}"

# --- Step 1: Build Hypervisor Host IFS ---
echo "=== Building Hypervisor Host IFS ==="
HOST_BUILD_DIR="${OUTPUT_DIR}/hyp-host-build"
mkdir -p "${HOST_BUILD_DIR}"

echo "Running mkqnximage for hypervisor host..."
mkqnximage --arch=aarch64le --type=qemu --qvm=yes --output="${HOST_BUILD_DIR}"

echo ""
echo "IMPORTANT: Manual IFS fixups required!"
echo "Edit ${HOST_BUILD_DIR}/ifs.build and apply these changes:"
echo ""
echo "  1. Replace 'startup-armv8_fm -H' with 'startup-qemu-virt -H'"
echo "  2. Fix smem addresses for QEMU virt:"
echo "     - Primary virtio-blk: smem=0xa003e00,irq=79"
echo "     - Add second virtio-blk: smem=0xa003c00,irq=78"
echo "  3. Add second devb-virtio driver line:"
echo "     devb-virtio blk smem=0xa003c00,irq=78"
echo ""
read -p "Press Enter after making the edits (or Ctrl+C to abort)..."

echo "Rebuilding host IFS with fixes..."
mkifs -v "${HOST_BUILD_DIR}/ifs.build" "${HOST_IFS_OUT}"
echo "Host IFS built: ${HOST_IFS_OUT}"

# --- Step 2: Build Guest IFS ---
echo ""
echo "=== Building Guest IFS ==="
GUEST_BUILD_DIR="${OUTPUT_DIR}/guest-build"
mkdir -p "${GUEST_BUILD_DIR}"

echo "Running mkqnximage for guest..."
mkqnximage --arch=aarch64le --type=qvm --output="${GUEST_BUILD_DIR}"

echo "Building guest IFS..."
mkifs -v "${GUEST_BUILD_DIR}/ifs.build" "${GUEST_IFS_OUT}"
echo "Guest IFS built: ${GUEST_IFS_OUT}"

# --- Step 3: Build ARM64 Trampoline ---
echo ""
echo "=== Building ARM64 Trampoline ==="

# Verify entry point
echo "Using QNX ELF entry point: ${QNX_ENTRY_POINT}"
echo "Verify with: readelf -h ${HOST_IFS_OUT} | grep 'Entry point'"

# Create trampoline assembly
TRAMP_ASM="${OUTPUT_DIR}/trampoline.S"
cat > "${TRAMP_ASM}" << 'TRAMP_EOF'
/*
 * ARM64 Image trampoline for QNX on QEMU virt
 *
 * This is original work, not derived from QNX source code.
 *
 * QEMU loads this as a Linux ARM64 Image (magic at offset 56).
 * It sets X0 = DTB address, then we jump to the real QNX ELF entry.
 * The QNX IFS is loaded separately via -device loader.
 */

.section .text
.globl _start

_start:
    /* ARM64 Image header — offsets 0-63 */
    b       entry                   /* code0: branch to real code */
    nop                             /* code1 */
    .quad   0x200000                /* text_offset: load at RAM+0x200000 = 0x40200000 */
    .quad   0x1000                  /* image_size (4KB, minimal) */
    .quad   0x0a                    /* flags: LE, 4K pages, anywhere */
    .quad   0                       /* res2 */
    .quad   0                       /* res3 */
    .quad   0                       /* res4 */
    .ascii  "ARM\x64"              /* magic: 0x644d5241 at offset 56 */
    .long   0                       /* PE offset: 0 (not PE) */

    /* Trampoline code — offset 64 */
entry:
    /* X0 already contains DTB address (set by QEMU for ARM64 Image) */
    /* Load QNX ELF entry point into X1 */
    ldr     x1, qnx_entry
    br      x1                      /* Jump to QNX */

    .align  3
qnx_entry:
    .quad   QNX_ENTRY               /* Filled in by build script */
TRAMP_EOF

# Assemble the trampoline
if command -v aarch64-linux-gnu-gcc &>/dev/null; then
    CROSS_PREFIX="aarch64-linux-gnu-"
elif command -v aarch64-none-elf-gcc &>/dev/null; then
    CROSS_PREFIX="aarch64-none-elf-"
else
    echo "WARNING: No aarch64 cross-compiler found."
    echo "Install aarch64-linux-gnu-gcc or assemble the trampoline manually."
    echo "Skipping trampoline build."
    CROSS_PREFIX=""
fi

if [ -n "${CROSS_PREFIX}" ]; then
    ${CROSS_PREFIX}gcc -DQNX_ENTRY=${QNX_ENTRY_POINT} \
        -nostdlib -nostartfiles -Wl,--section-start=.text=0 \
        -o "${OUTPUT_DIR}/trampoline.elf" "${TRAMP_ASM}"
    ${CROSS_PREFIX}objcopy -O binary "${OUTPUT_DIR}/trampoline.elf" "${TRAMPOLINE_OUT}"
    echo "Trampoline built: ${TRAMPOLINE_OUT}"
fi

# --- Step 4: Create Disk Images ---
echo ""
echo "=== Creating Disk Images ==="

# Host disk (256 MB)
echo "Creating host disk image (256 MB)..."
dd if=/dev/zero of="${HOST_DISK_OUT}" bs=1M count=256 status=progress

echo ""
echo "IMPORTANT: You must format and populate the host disk with:"
echo "  /data/guest.conf        — copy from qvm-guest.conf in this repo"
echo "  /data/qnx-guest-ifs.bin — the guest IFS binary"
echo ""
echo "Use QNX disk utilities or mount the image to populate it."

# Guest disk (128 MB)
echo "Creating guest disk image (128 MB)..."
dd if=/dev/zero of="${GUEST_DISK_OUT}" bs=1M count=128 status=progress

echo ""
echo "=== Build Complete ==="
echo ""
echo "Output files:"
echo "  Host IFS:      ${HOST_IFS_OUT}"
echo "  Guest IFS:     ${GUEST_IFS_OUT}"
echo "  Trampoline:    ${TRAMPOLINE_OUT}"
echo "  Host disk:     ${HOST_DISK_OUT}"
echo "  Guest disk:    ${GUEST_DISK_OUT}"
echo ""
echo "Next step: ./scripts/boot-qnx-hyp.sh ${OUTPUT_DIR}"
