#!/bin/bash
# build-initrd.sh — Build Linux QVM guest initrd with Perfetto tracing
#
# Repacks a Debian arm64 initrd with:
#   - virtio_blk.ko (for virtio-mmio block device support)
#   - Perfetto binaries (traced, traced_probes, perfetto)
#   - Custom init script (captures trace, writes to /dev/vda)
#
# Usage:
#   DEBIAN_INITRD=/path/to/initrd.gz \
#   PERFETTO_BINS=/path/to/perfetto-bins \
#   KERNEL_MODS=/path/to/kernel-modules \
#   OUTPUT=/tmp/initrd-linux-qvm.gz \
#   bash build-initrd.sh

set -e

DEBIAN_INITRD="${DEBIAN_INITRD:-/tmp/linux-guest/initrd.gz}"
PERFETTO_BINS="${PERFETTO_BINS:-/tmp/linux-guest/initramfs/bin}"
# Directory containing lib/modules/6.1.0-42-arm64/kernel/drivers/block/virtio_blk.ko
KERNEL_MODS="${KERNEL_MODS:-/tmp/deb-extract}"
OUTPUT="${OUTPUT:-/tmp/initrd-linux-qvm.gz}"
WORKDIR="${WORKDIR:-/tmp/initrd-build}"

echo "=== Building Linux QVM initrd ==="
echo "  Source initrd : $DEBIAN_INITRD"
echo "  Perfetto bins : $PERFETTO_BINS"
echo "  Kernel modules: $KERNEL_MODS"
echo "  Output        : $OUTPUT"
echo "  Work dir      : $WORKDIR"

# Clean workdir
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

# 1. Unpack Debian initrd
echo "[1/5] Unpacking Debian initrd..."
cd "$WORKDIR"
zcat "$DEBIAN_INITRD" | cpio -id 2>/dev/null
echo "  Files: $(find . -type f | wc -l)"

# 2. Add Perfetto binaries
echo "[2/5] Adding Perfetto binaries..."
for bin in traced traced_probes perfetto; do
  if [ -f "$PERFETTO_BINS/$bin" ]; then
    cp "$PERFETTO_BINS/$bin" bin/
    chmod +x "bin/$bin"
    echo "  Copied: $bin ($(du -h "bin/$bin" | cut -f1))"
  else
    echo "  ERROR: $PERFETTO_BINS/$bin not found" >&2
    exit 1
  fi
done

# 3. Add virtio_blk.ko
echo "[3/5] Adding virtio_blk.ko..."
KVER="6.1.0-42-arm64"
BLKMOD="$KERNEL_MODS/lib/modules/$KVER/kernel/drivers/block/virtio_blk.ko"
if [ -f "$BLKMOD" ]; then
  mkdir -p "lib/modules/$KVER/kernel/drivers/block"
  cp "$BLKMOD" "lib/modules/$KVER/kernel/drivers/block/"
  echo "  Copied: virtio_blk.ko"
else
  echo "  ERROR: virtio_blk.ko not found at $BLKMOD" >&2
  exit 1
fi

# 4. Install init script
echo "[4/5] Installing init script..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INIT_SCRIPT="${INIT_SCRIPT:-$SCRIPT_DIR/guest-init-v8.sh}"
echo "  Init script: $INIT_SCRIPT"
cp "$INIT_SCRIPT" init
chmod 755 init

# 5. Repack
echo "[5/5] Repacking initrd..."
find . | cpio -o -H newc 2>/dev/null | gzip -1 > "$OUTPUT"
SIZE=$(du -h "$OUTPUT" | cut -f1)
echo "  Output: $OUTPUT ($SIZE)"

echo "=== Build complete ==="
echo "  Transfer to QNX HV /dev/shmem/:"
echo "  sshpass -p root scp -P 2240 $OUTPUT root@localhost:/dev/shmem/initrd-linux-qvm.gz"
