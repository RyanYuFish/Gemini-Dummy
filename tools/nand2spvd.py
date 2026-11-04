#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""nand2spvd.py — 把裸 NAND dump 打包成 SPVD（Sunplus Virtual Disk）虚拟硬盘。

设计目标（VHD 类似物，但面向 Sunplus SPI-NAND 语义）：
  * 一个自描述容器：头部记录几何（page/oob/ppb/blocks）、坏块表、分区表；
  * 数据区为“去 OOB 的扁平页序列”，即客机按逻辑页顺序线性读取即可，
    不需要在宿主侧理解物理坏块的稀疏布局；
  * 可被 QEMU 的 sunplus-vdisk 设备直接 mmap / 线性读窗口加载。

用法：
  python3 nand2spvd.py <nand.bin> <out.spvd> [--geometry PAGE,OOB,PPB,BLOCKS]
  python3 nand2spvd.py --info <out.spvd>

默认几何 4096/256/64/2048（春风150aura XT26G04C：4352 B/帧，131072 页）。
若不给 --geometry，会按文件大小自动判定候选几何。

SPVD v1 布局（小端）：
  0x000  char magic[4]   "SPVD"
  0x004  u32  version    = 1
  0x008  u32  page_size
  0x00C  u32  oob_size
  0x010  u32  pages_per_block
  0x014  u32  block_count
  0x018  u32  page_count        (= block_count * pages_per_block)
  0x01C  u32  data_offset       (= 0x1000)
  0x020  u64  data_size         (= page_count * page_size)
  0x028  u32  bad_block_count
  0x02C  u32  partition_count
  0x030  u32  flags             (bit0: partition table present)
  0x034  u32  header_crc32      (覆盖 0x000..0x034)
  0x038  u32  reserved
  0x100  u32  bad_blocks[bad_block_count]
  0x400  partition entries: { char name[32]; u32 data_addr; u32 size; u32 reserved } *
  0x1000 data:  page_count 个 page_size 字节的扁平页（OOB 已剔除）
"""
import os
import struct
import sys
import zlib

MAGIC = b"SPVD"
VERSION = 1
HEADER_SIZE = 0x1000
BAD_OFF = 0x100
PART_OFF = 0x400
PART_NAME_LEN = 32
PART_ENTRY = PART_NAME_LEN + 4 + 4 + 4  # 44

# 150Aura（XT26G04C）真实分区表，25 项。
# 来源：本机 dump 里 userdata 保存的真车启动日志（`Creating 25 MTD partitions`
# 逐行区间），与内核 cmdlinepart 完全一致；地址是**去 OOB 的扁平字节偏移**。
# 注意名字带点（"rootfs." "spsdk." ...）是厂商原样写法，不要改。
DEFAULT_PARTITIONS = [
    ("nand_header", 0x00000000, 0x00040000),
    ("xboot1", 0x00040000, 0x00040000),
    ("uboot1", 0x00080000, 0x000C0000),
    ("uboot2", 0x00140000, 0x001C0000),
    ("env", 0x00300000, 0x00080000),
    ("env_redund", 0x00380000, 0x00080000),
    ("ecos", 0x00400000, 0x00400000),
    ("kernel", 0x00800000, 0x00480000),
    ("rootfs.", 0x00C80000, 0x00480000),
    ("opt.", 0x01100000, 0x00080000),
    ("spsdk.", 0x01180000, 0x03000000),
    ("spapp.", 0x04180000, 0x04040000),
    ("nvm", 0x081C0000, 0x01000000),
    ("pq", 0x091C0000, 0x00040000),
    ("tcon", 0x09200000, 0x00040000),
    ("iop_car", 0x09240000, 0x00040000),
    ("runtime_cfg", 0x09280000, 0x00100000),
    ("vi", 0x09380000, 0x00040000),
    ("isp_logo", 0x093C0000, 0x00980000),
    ("vendordata", 0x09D40000, 0x00040000),
    ("pat_logo", 0x09D80000, 0x00BC0000),
    ("version_info", 0x0A940000, 0x00040000),
    ("vd_restore", 0x0A980000, 0x00040000),
    ("anm_logo", 0x0A9C0000, 0x00100000),
    ("userdata", 0x0AAC0000, 0x15540000),
]


def auto_geometry(size):
    cands = [(4096, 256), (2048, 128), (2048, 64), (4096, 128)]
    for page, oob in cands:
        frame = page + oob
        if size % frame == 0:
            pages = size // frame
            for ppb in (64, 128, 32):
                if pages % ppb == 0:
                    blocks = pages // ppb
                    if blocks in (2048, 1024, 4096):
                        return page, oob, ppb, blocks
    raise SystemExit("无法自动判定几何；请用 --geometry PAGE,OOB,PPB,BLOCKS 指定")


def detect_bad_blocks(fh, page, oob, ppb, blocks):
    """坏块标记：块内 page0/page1 的 OOB 首字节 != 0xFF。"""
    frame = page + oob
    bad = []
    for b in range(blocks):
        for pg in (0, 1):
            off = ((b * ppb + pg) * frame) + page
            fh.seek(off)
            m = fh.read(2)
            if len(m) == 2 and (m[0] != 0xFF or m[1] != 0xFF):
                bad.append(b)
                break
    return bad


def build(src, dst, page, oob, ppb, blocks, partitions):
    frame = page + oob
    page_count = blocks * ppb
    data_size = page_count * page
    fh = open(src, "rb")
    real = os.path.getsize(src)
    expect = page_count * frame
    if real != expect:
        raise SystemExit(f"源大小不符：{real} != {expect}（几何 {page}/{oob}/{ppb}/{blocks}）")

    bad = detect_bad_blocks(fh, page, oob, ppb, blocks)
    print(f"[*] 几何 page={page} oob={oob} ppb={ppb} blocks={blocks} pages={page_count}")
    print(f"[*] 坏块 {len(bad)}: {bad}")

    # 头部
    hdr = bytearray(HEADER_SIZE)
    struct.pack_into("<4sIIIIIII", hdr, 0x00, MAGIC, VERSION, page, oob, ppb,
                     blocks, page_count, HEADER_SIZE)
    struct.pack_into("<Q", hdr, 0x20, data_size)
    flags = 0x1 if partitions else 0x0
    struct.pack_into("<IIII", hdr, 0x28, len(bad), len(partitions), flags, 0)
    # 坏块表
    for i, b in enumerate(bad):
        struct.pack_into("<I", hdr, BAD_OFF + i * 4, b)
    # 分区表
    for i, (name, addr, size) in enumerate(partitions):
        base = PART_OFF + i * PART_ENTRY
        nb = name.encode("ascii")[:PART_NAME_LEN - 1]
        hdr[base:base + len(nb)] = nb
        struct.pack_into("<II", hdr, base + PART_NAME_LEN, addr, size)
    # 头部 CRC（覆盖 0..0x34）
    struct.pack_into("<I", hdr, 0x34, zlib.crc32(bytes(hdr[0:0x34])) & 0xFFFFFFFF)

    with open(dst, "wb") as out:
        out.write(hdr)
        # 扁平化：逐页读 page_size，跳过 OOB
        done = 0
        for p in range(page_count):
            fh.seek(p * frame)
            pg = fh.read(page)
            if len(pg) != page:
                raise SystemExit(f"源在读第 {p} 页时提前结束")
            out.write(pg)
            done += 1
            if done % 32768 == 0:
                print(f"    已写入 {done}/{page_count} 页 …")
    fh.close()
    print(f"[✓] 写出 {dst}  ({os.path.getsize(dst)} 字节, 数据 {data_size} 字节)")


def info(path):
    with open(path, "rb") as fh:
        hdr = fh.read(HEADER_SIZE)
    if hdr[:4] != MAGIC:
        raise SystemExit("不是 SPVD 文件（magic 不符）")
    (magic, ver, page, oob, ppb, blocks, pcount, doff) = struct.unpack_from("<4sIIIIIII", hdr, 0)
    dsize, = struct.unpack_from("<Q", hdr, 0x20)
    badn, partn, flags, _ = struct.unpack_from("<IIII", hdr, 0x28)
    crc, = struct.unpack_from("<I", hdr, 0x34)
    ok = (zlib.crc32(bytes(hdr[0:0x34])) & 0xFFFFFFFF) == crc
    print(f"SPVD v{ver}  magic={magic!r}  crc={'ok' if ok else 'BAD'}")
    print(f"  page={page} oob={oob} ppb={ppb} blocks={blocks} pages={pcount} data={dsize}")
    print(f"  bad_blocks={badn}: " +
          str([struct.unpack_from("<I", hdr, BAD_OFF + i * 4)[0] for i in range(badn)]))
    print(f"  partitions={partn} flags={flags:#x}")
    for i in range(partn):
        base = PART_OFF + i * PART_ENTRY
        name = hdr[base:PART_OFF + i * PART_ENTRY + PART_NAME_LEN].split(b"\x00")[0].decode("ascii", "replace")
        addr, size = struct.unpack_from("<II", hdr, base + PART_NAME_LEN)
        print(f"    {name:12s} addr=0x{addr:08X} size=0x{size:08X}")


def main(argv):
    if len(argv) >= 2 and argv[1] == "--info":
        info(argv[2])
        return
    if len(argv) < 3:
        print(__doc__)
        raise SystemExit(1)
    src, dst = argv[1], argv[2]
    geo = None
    parts = DEFAULT_PARTITIONS
    i = 3
    while i < len(argv):
        if argv[i] == "--geometry" and i + 1 < len(argv):
            page, oob, ppb, blocks = (int(x, 0) for x in argv[i + 1].split(","))
            geo = (page, oob, ppb, blocks)
            i += 2
        else:
            i += 1
    if geo is None:
        geo = auto_geometry(os.path.getsize(src))
        print(f"[i] 自动判定几何: {geo}")
    build(src, dst, *geo, parts)


if __name__ == "__main__":
    main(sys.argv)
