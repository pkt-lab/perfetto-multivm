#!/bin/bash
# Build Linux guest initrd for CENTRAL traced role
#
# Takes the v12 initrd (with full busybox) and adds upstream
# traced + traced_probes + perfetto + libperfetto.so + libstdc++
#
# Usage:
#   bash build-initrd-linux-central.sh
#
# Inputs:
#   BASE_INITRD     Base initrd with busybox (default: /tmp/initrd-v12.gz)
#   PERFETTO_OUT    Upstream perfetto build dir (default: /tmp/linux-bins-stripped)
#   LIBSTDCXX       Path to libstdc++.so.6 (default: auto-detect from AGL initrd)
#   TRACE_CONFIG    Trace config to bundle (default: configs/linux-central-3vm.pbtxt)
#
# Output: /tmp/initrd-linux-central.gz
#
# IMPORTANT: Use initrd-v12.gz (full busybox, 1.9MB) NOT initrd-agl-vsock.gz
# (67KB stripped busybox missing shell/mount applets).

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_INITRD="${BASE_INITRD:-/tmp/initrd-v12.gz}"
PERFETTO_OUT="${PERFETTO_OUT:-/tmp/linux-bins-stripped}"
TRACE_CONFIG="${TRACE_CONFIG:-${SCRIPT_DIR}/../configs/multivm-3vm.pbtxt}"
LIBSTDCXX="${LIBSTDCXX:-}"
WORK=/tmp/initrd-central-work
OUT=/tmp/initrd-linux-central.gz

[ -f "$BASE_INITRD" ] || { echo "ERROR: Base initrd not found: $BASE_INITRD"; exit 1; }
[ -f "$PERFETTO_OUT/traced" ] || { echo "ERROR: traced not found in $PERFETTO_OUT"; exit 1; }
[ -f "$PERFETTO_OUT/perfetto" ] || { echo "ERROR: perfetto not found in $PERFETTO_OUT"; exit 1; }
[ -f "$PERFETTO_OUT/libperfetto.so" ] || { echo "ERROR: libperfetto.so not found in $PERFETTO_OUT"; exit 1; }

# Find libstdc++ if not specified
if [ -z "$LIBSTDCXX" ]; then
    for candidate in \
        /usr/lib/aarch64-linux-gnu/libstdc++.so.6; do
        if [ -f "$candidate" ]; then
            LIBSTDCXX="$candidate"
            break
        fi
    done
fi
[ -f "$LIBSTDCXX" ] || { echo "ERROR: libstdc++.so.6 not found. Set LIBSTDCXX env var."; exit 1; }

echo "=== Building Linux Central Traced initrd ==="
echo "  Base    : $BASE_INITRD"
echo "  Perfetto: $PERFETTO_OUT"
echo "  libstdc++: $LIBSTDCXX"
echo "  Config  : $TRACE_CONFIG"

# Extract base initrd
rm -rf "$WORK" && mkdir -p "$WORK"
cd "$WORK"
zcat "$BASE_INITRD" | cpio -idm 2>/dev/null

# Remove relay binaries (this guest IS the central)
rm -f bin/traced_relay

# Replace/add perfetto binaries
for BIN in traced traced_probes perfetto; do
    cp "$PERFETTO_OUT/$BIN" "bin/$BIN"
    chmod 755 "bin/$BIN"
done

# Add libperfetto.so
for LIBDIR in lib lib/aarch64-linux-gnu; do
    if [ -d "$LIBDIR" ]; then
        cp "$PERFETTO_OUT/libperfetto.so" "$LIBDIR/libperfetto.so"
        chmod 755 "$LIBDIR/libperfetto.so"
    fi
done

# Add libstdc++ (upstream perfetto links to it via libperfetto.so)
for LIBDIR in lib lib/aarch64-linux-gnu; do
    if [ -d "$LIBDIR" ]; then
        cp "$LIBSTDCXX" "$LIBDIR/libstdc++.so.6"
        chmod 755 "$LIBDIR/libstdc++.so.6"
    fi
done

# Add busybox symlinks
for cmd in nc awk ip ping insmod; do
    ln -sf busybox "bin/$cmd" 2>/dev/null || true
done

# Clean fstab (prevents busybox mount confusion)
echo "" > etc/fstab 2>/dev/null || true

# Bundle trace config
mkdir -p etc
if [ -f "$TRACE_CONFIG" ]; then
    cp "$TRACE_CONFIG" etc/multivm-3vm.pbtxt
    echo "  Bundled trace config"
fi

# Replace init script
cp "$SCRIPT_DIR/init-linux-central.sh" init
chmod 755 init

# Show contents
echo ""
echo "  Perfetto binaries:"
ls -lh bin/traced bin/traced_probes bin/perfetto lib/libperfetto.so lib/libstdc++.so.6 2>/dev/null | awk '{print "    " $9 " (" $5 ")"}'

# Pack
find . | cpio -o -H newc 2>/dev/null | gzip > "$OUT"
echo ""
echo "  Output: $OUT ($(du -h "$OUT" | cut -f1))"
echo "=== Done ==="
