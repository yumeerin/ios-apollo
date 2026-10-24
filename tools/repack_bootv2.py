#!/usr/bin/env python3
"""Repack an Android boot image v2 using a verified stock header.

Samsung's r8q ABL expects the stock physical addresses (kernel 0x8000,
ramdisk 0x2000000, tags 0x1e00000, dtb 0x1f00000). Instead of relying on
mkbootimg, copy the stock header and replace only the kernel, ramdisk and
DTB payloads, updating the sizes and the v2 SHA-1 id.

Usage:
  repack_bootv2.py --template stock-boot.img --kernel shim.bin \
      --ramdisk payload.bin --dtb r8q.dtb -o shim-boot-r8q.img
"""
import argparse
import hashlib
import os
import struct
import sys

BOOT_MAGIC = b"ANDROID!"
HEADER_V2_MIN = 1660


def u32(buf, off):
    return struct.unpack_from("<I", buf, off)[0]


def u64(buf, off):
    return struct.unpack_from("<Q", buf, off)[0]


def padded(buf, page_size):
    return buf + b"\0" * ((page_size - len(buf) % page_size) % page_size)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--template", required=True,
                    help="stock Android boot image v2 (header source)")
    ap.add_argument("--kernel", required=True, help="new kernel/shim flat binary")
    ap.add_argument("--ramdisk", required=True, help="new ramdisk (the XNU payload)")
    ap.add_argument("--dtb", required=True, help="new DTB")
    ap.add_argument("-o", "--output", required=True)
    args = ap.parse_args()

    template = open(args.template, "rb").read()
    kernel = open(args.kernel, "rb").read()
    ramdisk = open(args.ramdisk, "rb").read()
    dtb = open(args.dtb, "rb").read()

    if template[:8] != BOOT_MAGIC:
        sys.exit("template is not an Android boot image")
    if len(template) < HEADER_V2_MIN:
        sys.exit("template is too small")

    kernel_addr = u32(template, 12)
    ramdisk_addr = u32(template, 20)
    tags_addr = u32(template, 32)
    page_size = u32(template, 36)
    header_version = u32(template, 40)
    header_size = u32(template, 1644)
    dtb_addr = u64(template, 1652)

    if header_version != 2:
        sys.exit(f"template header version is {header_version}, need 2")
    if page_size < HEADER_V2_MIN or page_size & (page_size - 1):
        sys.exit(f"bad template page size {page_size}")
    if header_size < HEADER_V2_MIN or header_size > page_size:
        sys.exit(f"bad template header size {header_size}")
    if u32(template, 24) != 0 or u32(template, 1632) != 0:
        sys.exit("template has a second stage or recovery dtbo; not supported")

    header = bytearray(template[:page_size])
    struct.pack_into("<I", header, 8, len(kernel))
    struct.pack_into("<I", header, 16, len(ramdisk))
    struct.pack_into("<I", header, 24, 0)
    struct.pack_into("<I", header, 1648, len(dtb))

    # mkbootimg v0-v2: SHA-1(data + LE32(size)) for kernel, ramdisk, second,
    # recovery_dtbo and dtb; absent images contribute a zero size.
    sha = hashlib.sha1()
    for blob in (kernel, ramdisk, b"", b"", dtb):
        sha.update(blob)
        sha.update(struct.pack("<I", len(blob)))
    digest = sha.digest()
    header[576:608] = digest.ljust(32, b"\0")

    out = bytearray(header)
    out += padded(kernel, page_size)
    out += padded(ramdisk, page_size)
    out += padded(dtb, page_size)

    os.makedirs(os.path.dirname(os.path.abspath(args.output)), exist_ok=True)
    open(args.output, "wb").write(out)

    print(f"kernel:  {len(kernel):>10} bytes, load {kernel_addr:#x}, file offset {page_size:#x}")
    print(f"ramdisk: {len(ramdisk):>10} bytes, load {ramdisk_addr:#x}, file offset {page_size + len(padded(kernel, page_size)):#x}")
    print(f"dtb:     {len(dtb):>10} bytes, load {dtb_addr:#x}, file offset {page_size + len(padded(kernel, page_size)) + len(padded(ramdisk, page_size)):#x}")
    print(f"tags:    load {tags_addr:#x}, page size {page_size}, header v{header_version}")
    print(f"id:      {digest.hex()}")
    print(f"image:   {len(out)} bytes -> {args.output}")


if __name__ == "__main__":
    main()
