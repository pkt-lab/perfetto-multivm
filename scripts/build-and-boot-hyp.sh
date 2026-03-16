#!/usr/bin/env bash
# Build and boot QNX 8.0 Hypervisor on QEMU aarch64 (TCG)
#
# Prerequisites:
#   - QNX SDP 8.0 environment sourced (qnxsdp-env.sh)
#   - qemu-system-aarch64, sshpass installed
#
# Usage:
#   ./scripts/build-and-boot-hyp.sh [WORKDIR] [--ssh-port PORT] [--no-boot]
#
# SPDX-License-Identifier: MIT

set -euo pipefail

WORKDIR="${1:-/tmp/qnx-hyp-build}"
SSH_PORT="${SSH_PORT:-2240}"
TRAMPOLINE_ENTRY="0x80000da8"
NO_BOOT=false

for arg in "$@"; do
  case "$arg" in
    --ssh-port=*) SSH_PORT="${arg#*=}" ;;
    --no-boot) NO_BOOT=true ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

# --- Verify environment ---
if ! command -v mkqnximage &>/dev/null; then
  echo "ERROR: mkqnximage not found. Source qnxsdp-env.sh first." >&2
  exit 1
fi

if ! command -v qemu-system-aarch64 &>/dev/null; then
  echo "ERROR: qemu-system-aarch64 not found." >&2
  exit 1
fi

echo "==> Building QNX HV image in $WORKDIR"
mkdir -p "$WORKDIR"
cd "$WORKDIR"

# --- Step 1: Generate base image ---
echo "==> Step 1: mkqnximage --arch=aarch64le --type=qvm"
mkqnximage --arch=aarch64le --type=qvm --qvm=yes --clean --build 2>&1 | tail -5

# --- Step 2: Fix build files ---
echo "==> Step 2: Patching ifs.build and startup.sh for QEMU virt"

# Fix startup binary
sed -i 's/startup-armv8_fm -H/startup-qemu-virt -H/' output/build/ifs.build

# Fix devb-virtio MMIO address
sed -i 's/smem=0x1c0d0000,irq=41/smem=0x0a003e00,irq=79/' output/build/startup.sh

# Disable devc-virtio (ARM FM MMIO, Bus Error on QEMU virt)
sed -i 's|^ *devc-virtio -e 0x[0-9a-f]*,[0-9]*|# devc-virtio disabled for QEMU virt|' output/build/startup.sh

# Disable vcon1 (no virtual console on QEMU virt)
sed -i 's|^on  -d -t /dev/vcon1|# on -d -t /dev/vcon1  # disabled for QEMU virt|' output/build/startup.sh

echo "   Patched: startup-qemu-virt -H, smem=0x0a003e00, devc-virtio disabled"

# --- Step 3: Rebuild IFS ---
echo "==> Step 3: Rebuilding IFS"
mkifs output/build/ifs.build output/ifs-rebuilt.bin 2>&1 | tail -3

ENTRY=$(readelf -h output/ifs-rebuilt.bin 2>/dev/null | grep 'Entry' | awk '{print $NF}')
echo "   IFS entry point: $ENTRY"

if [ "$ENTRY" != "$TRAMPOLINE_ENTRY" ]; then
  echo "WARNING: Entry point $ENTRY != expected $TRAMPOLINE_ENTRY"
  echo "         You may need to rebuild the trampoline with --entry=$ENTRY"
fi

# --- Step 4: Build trampoline ---
TRAMPOLINE="$WORKDIR/qnx-tramp-hyp.img"
if [ -f "$REPO_DIR/docs/qnx-hypervisor/trampoline/build-trampoline.py" ]; then
  echo "==> Step 4: Building trampoline"
  python3 "$REPO_DIR/docs/qnx-hypervisor/trampoline/build-trampoline.py" \
    --entry "$ENTRY" --dtb 0x40000000 -o "$TRAMPOLINE"
  echo "   Trampoline: $TRAMPOLINE"
else
  echo "==> Step 4: Trampoline builder not found, checking for existing..."
  if [ ! -f "$TRAMPOLINE" ]; then
    echo "ERROR: No trampoline at $TRAMPOLINE. Run build-trampoline.py manually." >&2
    exit 1
  fi
fi

if [ "$NO_BOOT" = true ]; then
  echo "==> Build complete (--no-boot). Files:"
  echo "    IFS:        $WORKDIR/output/ifs-rebuilt.bin"
  echo "    Disk:       $WORKDIR/output/disk-qvm"
  echo "    Trampoline: $TRAMPOLINE"
  exit 0
fi

# --- Step 5: Kill existing QEMU on same port ---
EXISTING_PID=$(lsof -ti tcp:$SSH_PORT 2>/dev/null || true)
if [ -n "$EXISTING_PID" ]; then
  echo "==> Killing existing process on port $SSH_PORT (PID $EXISTING_PID)"
  kill "$EXISTING_PID" 2>/dev/null || true
  sleep 2
fi

# --- Step 6: Boot ---
SERIAL_LOG="$WORKDIR/serial.log"
echo "==> Step 5: Booting QEMU (SSH port $SSH_PORT, serial log: $SERIAL_LOG)"

qemu-system-aarch64 \
  -machine virt-4.2,virtualization=on,gic-version=3 \
  -cpu cortex-a57 -smp 2 -m 2G \
  -kernel "$TRAMPOLINE" \
  -device loader,file="$WORKDIR/output/ifs-rebuilt.bin" \
  -drive file="$WORKDIR/output/disk-qvm",format=raw,if=none,id=drv0,snapshot=on \
  -device virtio-blk-device,drive=drv0 \
  -device virtio-net-device,netdev=net0 \
  -netdev user,id=net0,hostfwd=tcp::${SSH_PORT}-:22 \
  -object rng-random,filename=/dev/urandom,id=rng0 \
  -device virtio-rng-device,rng=rng0 \
  -serial file:"$SERIAL_LOG" \
  -display none -daemonize

echo "==> Waiting for boot (30s)..."
sleep 30

echo "==> Serial log:"
cat "$SERIAL_LOG"

echo ""
echo "==> Testing SSH..."
if timeout 10 sshpass -p root ssh -p "$SSH_PORT" \
  -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
  root@localhost "uname -a; ls /system/bin/qvm && echo QVM_OK" 2>/dev/null; then
  echo ""
  echo "==> SUCCESS: QNX Hypervisor is running on port $SSH_PORT"
else
  echo "==> SSH failed. Check serial log: $SERIAL_LOG"
  exit 1
fi
