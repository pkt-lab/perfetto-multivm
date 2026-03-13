#!/usr/bin/env python3
"""
build-trampoline.py — Build the 128-byte ARM64 Image trampoline for QNX boot under QEMU

Problem: QEMU only sets X0=DTB for Linux ARM64 Image format (magic 0x644d5241).
         QNX IFS is ELF — QEMU sets X0=0, FDT parse fails, boot hangs at WFE.

Solution: 128-byte header with ARM64 magic at offset 56.
- text_offset=0x00200000 → trampoline loads at RAM_BASE + 0x200000 (0x40200000)
- Trampoline sets up X16 and jumps to QNX ELF entry point
- QNX IFS loaded separately via: -device loader,file=ifs.bin

Usage:
    python3 build-trampoline.py [entry_hex] [output]
    python3 build-trampoline.py 0x80000da8 qnx-tramp-hyp.img

QEMU command:
    qemu-system-aarch64 -kernel qnx-tramp-hyp.img \
      -device loader,file=qnx-ifs.bin ...
"""

import struct, sys

def build(entry: int, out: str) -> None:
    hdr = bytearray(128)

    # Code at offset 0-7: MOVZ X16, #(entry_lo); B #8 (skip text_offset field)
    e0 = (entry >>  0) & 0xFFFF
    e1 = (entry >> 16) & 0xFFFF
    movz  = 0xd2800010 | (e0 << 5)   # MOVZ X16, #e0
    b_fwd = 0x14000002                 # B +8 (skip text_offset word at offset 8)
    struct.pack_into('<I', hdr, 0, movz)
    struct.pack_into('<I', hdr, 4, b_fwd)

    # text_offset at offset 8 (ARM64 Image header field)
    struct.pack_into('<Q', hdr, 8, 0x00200000)

    # Continue code after text_offset (at offset 16)
    movk = 0xf2a00010 | (e1 << 5)    # MOVK X16, #e1, LSL#16
    br   = 0xd61f0200                  # BR X16
    struct.pack_into('<I', hdr, 16, movk)
    struct.pack_into('<I', hdr, 20, br)

    # NOPs for padding (offsets 24-55)
    for i in range(24, 56, 4):
        struct.pack_into('<I', hdr, i, 0xd503201f)

    # ARM64 Image magic at offset 56
    struct.pack_into('<I', hdr, 56, 0x644d5241)  # "ARMd" LE

    with open(out, 'wb') as f:
        f.write(bytes(hdr))
    print(f"[+] Written {len(hdr)} bytes → {out}")
    print(f"[+] Entry: {entry:#x}, loads at: 0x40200000 (text_offset=0x200000)")
    print(f"[!] DTB will be at 0x40000000 (X0 set by QEMU)")
    print(f"[!] Load QNX IFS via: -device loader,file=<ifs.bin>")

if __name__ == '__main__':
    entry = int(sys.argv[1], 16) if len(sys.argv) > 1 else 0x80000da8
    out   = sys.argv[2] if len(sys.argv) > 2 else 'qnx-tramp.img'
    build(entry, out)
