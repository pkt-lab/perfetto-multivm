#!/usr/bin/env bash
# boot-qnx-hyp.sh — Launch QNX 8.0 Hypervisor in QEMU
#
# LICENSE WARNING: QNX SDP 8.0 is PROPRIETARY SOFTWARE owned by BlackBerry QNX.
# You MUST have a valid QNX license for the QNX images being booted.
# This script does not include any QNX binaries or source code.
#
# Usage:
#   ./boot-qnx-hyp.sh [image_dir]
#
# Default image_dir: /tmp

set -euo pipefail

IMAGE_DIR="${1:-/tmp}"

# --- File paths ---
TRAMPOLINE="${IMAGE_DIR}/qnx-tramp-hyp.img"
HOST_IFS="${IMAGE_DIR}/qnx-hyp-final.bin"
HOST_DISK="${IMAGE_DIR}/qnx-hypF-disk.img"
GUEST_DISK="${IMAGE_DIR}/qnx-guest-disk.img"
SERIAL_LOG="${IMAGE_DIR}/qnx-hypF.log"
MONITOR_SOCK="${IMAGE_DIR}/qemu-hypF.sock"

# --- QEMU configuration ---
QEMU_BIN="${QEMU_BIN:-qemu-system-aarch64}"
MACHINE="virt-4.2,virtualization=on,gic-version=3"
CPU="cortex-a57"
SMP="2"
MEMORY="2G"
SSH_PORT="${SSH_PORT:-2238}"

# --- Validation ---
if ! command -v "${QEMU_BIN}" &>/dev/null; then
    echo "ERROR: ${QEMU_BIN} not found. Install QEMU for aarch64."
    exit 1
fi

for f in "${TRAMPOLINE}" "${HOST_IFS}" "${HOST_DISK}" "${GUEST_DISK}"; do
    if [ ! -f "$f" ]; then
        echo "ERROR: Required file not found: $f"
        echo "Run build-hyp.sh first, or set image directory: $0 /path/to/images"
        exit 1
    fi
done

# Clean up stale monitor socket
rm -f "${MONITOR_SOCK}"

echo "=== QNX 8.0 Hypervisor on QEMU ==="
echo "  Machine:    ${MACHINE}"
echo "  CPU:        ${CPU} x${SMP}"
echo "  RAM:        ${MEMORY}"
echo "  SSH:        localhost:${SSH_PORT}"
echo "  Serial log: ${SERIAL_LOG}"
echo "  Monitor:    ${MONITOR_SOCK}"
echo ""
echo "Connect via:"
echo "  ssh -p ${SSH_PORT} root@localhost"
echo ""
echo "Monitor access:"
echo "  socat - UNIX-CONNECT:${MONITOR_SOCK}"
echo ""
echo "Starting QEMU..."

exec "${QEMU_BIN}" \
    -machine "${MACHINE}" \
    -cpu "${CPU}" \
    -smp "${SMP}" \
    -m "${MEMORY}" \
    \
    -kernel "${TRAMPOLINE}" \
    -device loader,file="${HOST_IFS}" \
    \
    -drive file="${HOST_DISK}",format=raw,if=none,id=drv0 \
    -device virtio-blk-device,drive=drv0 \
    \
    -drive file="${GUEST_DISK}",format=raw,if=none,id=drv1 \
    -device virtio-blk-device,drive=drv1 \
    \
    -device virtio-net-device,netdev=net0 \
    -netdev user,id=net0,hostfwd=tcp::${SSH_PORT}-:22 \
    \
    -object rng-random,filename=/dev/urandom,id=rng0 \
    -device virtio-rng-device,rng=rng0 \
    \
    -serial file:"${SERIAL_LOG}" \
    -display none \
    -monitor unix:"${MONITOR_SOCK}",server,nowait
