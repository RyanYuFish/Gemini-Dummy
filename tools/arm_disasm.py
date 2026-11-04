#!/usr/bin/env python3
"""反汇编 32 位 ARM ELF 里的单个函数（按符号名定位，用 capstone）。

用途：读 guest 自己的实现，例如
  - `mcucom_rx_ride_info_update` —— 35B ride-info 记录里哪个偏移是 speed/gear
  - `cfcp_parse_prop_data`       —— vhal frame array 的元素语义

用法：
  python3 Gemini-Dummy/tools/arm_disasm.py <elf.so> ride_info
  python3 Gemini-Dummy/tools/arm_disasm.py <elf.so> mcucom_rx_ride_info_update --n 200
  python3 Gemini-Dummy/tools/arm_disasm.py <elf.so> --list ride          # 只列符号
  python3 Gemini-Dummy/tools/arm_disasm.py <elf.so> --addr 0x397c4 --n 120
"""
import argparse
import struct
import sys

try:
    from capstone import Cs, CS_ARCH_ARM, CS_MODE_ARM, CS_MODE_THUMB
except ImportError:
    sys.exit("需要 capstone：pip install capstone")


def parse_elf(path):
    d = open(path, "rb").read()
    if d[:4] != b"\x7fELF":
        raise SystemExit("不是 ELF")
    is64 = d[4] == 2
    if is64:
        raise SystemExit("只处理 32 位 ELF")
    le = d[5] == 1
    e = "<" if le else ">"
    e_shoff = struct.unpack_from(e + "I", d, 0x20)[0]
    e_shentsize = struct.unpack_from(e + "H", d, 0x2E)[0]
    e_shnum = struct.unpack_from(e + "H", d, 0x30)[0]
    e_shstrndx = struct.unpack_from(e + "H", d, 0x32)[0]

    secs = []
    for i in range(e_shnum):
        off = e_shoff + i * e_shentsize
        name, typ, flags, addr, offset, size, link, info, align, entsize = \
            struct.unpack_from(e + "10I", d, off)
        secs.append(dict(name_off=name, type=typ, flags=flags, addr=addr,
                         offset=offset, size=size, link=link, entsize=entsize))

    shstr = secs[e_shstrndx]
    def shname(o):
        s = shstr["offset"] + o
        end = d.find(b"\0", s)
        return d[s:end].decode("latin1")

    for s in secs:
        s["name"] = shname(s["name_off"])
    return d, secs


def symbols(d, secs, e="<"):
    out = []
    for s in secs:
        if s["type"] not in (2, 11):      # SYMTAB / DYNSYM
            continue
        strtab = secs[s["link"]]
        n = s["size"] // 16
        for i in range(n):
            off = s["offset"] + i * 16
            name_off, value, size, info, other, shndx = \
                struct.unpack_from(e + "IIIBBH", d, off)
            if not name_off:
                continue
            p = strtab["offset"] + name_off
            end = d.find(b"\0", p)
            name = d[p:end].decode("latin1")
            out.append(dict(name=name, value=value, size=size,
                            thumb=bool(value & 1) or bool(info & 1),
                            shndx=shndx))
    return out


def va_to_off(secs, va):
    for s in secs:
        if s["type"] == 8 and s["addr"] <= va < s["addr"] + s["size"]:
            return s["offset"] + (va - s["addr"])
    return va


def text_sections(secs):
    return [s for s in secs if s["type"] == 1 and s["flags"] & 4 and s["size"]]


def callers(d, secs, target):
    """扫全 .text，找出目标地址的所有 bl/blx 调用点。"""
    hits = []
    want = target & ~1
    for s in text_sections(secs):
        code = d[s["offset"]:s["offset"] + s["size"]]
        base = s["addr"]
        md = Cs(CS_ARCH_ARM, CS_MODE_THUMB)
        md.skipdata = True
        for ins in md.disasm(code, base):
            if ins.mnemonic not in ("bl", "blx", "b.w"):
                continue
            try:
                dst = int(ins.op_str.lstrip("#"), 0)
            except ValueError:
                continue
            if (dst & ~1) == want:
                hits.append((ins.address, s["name"]))
    return sorted(set(hits))


def disasm(code, base_va, thumb, n):
    md = Cs(CS_ARCH_ARM, CS_MODE_THUMB if thumb else CS_MODE_ARM)
    md.detail = False
    out = []
    for ins in md.disasm(code, base_va):
        out.append(ins)
        if len(out) >= n:
            break
    return out


def scan_text(d, secs, syms, needle):
    """全 .text 反汇编，打印含 needle 的指令（附最近的前置符号名）。"""
    syms_sorted = sorted([x for x in syms if x["shndx"] != 0],
                         key=lambda x: x["value"] & ~1)
    hits = 0
    for s in text_sections(secs):
        code = d[s["offset"]:s["offset"] + s["size"]]
        md = Cs(CS_ARCH_ARM, CS_MODE_THUMB)
        md.skipdata = True
        cur = ""
        for ins in md.disasm(code, s["addr"]):
            # 更新最近的符号
            lo, hi = 0, len(syms_sorted) - 1
            best = ""
            while lo <= hi:
                mid = (lo + hi) // 2
                if (syms_sorted[mid]["value"] & ~1) <= ins.address:
                    best = syms_sorted[mid]["name"]
                    lo = mid + 1
                else:
                    hi = mid - 1
            if best != cur:
                cur = best
            line = f"{ins.mnemonic} {ins.op_str}"
            if needle.lower() in line.lower():
                print(f"  0x{ins.address:08x}  [{cur[:70]}]  {line}")
                hits += 1
    print(f"共 {hits} 处")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("elf")
    ap.add_argument("symbol", nargs="?", default="")
    ap.add_argument("--n", type=int, default=100)
    ap.add_argument("--addr", type=lambda x: int(x, 0), default=None)
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--callers", action="store_true",
                    help="列出所有调用该符号的位置")
    ap.add_argument("--scan", metavar="TEXT",
                    help="全 .text 反汇编，打印含该文本的指令")
    args = ap.parse_args()

    d, secs = parse_elf(args.elf)
    syms = symbols(d, secs)

    if args.scan:
        scan_text(d, secs, syms, args.scan)
        return

    if args.list or not (args.symbol or args.addr is not None):
        hits = [s for s in syms if args.symbol.lower() in s["name"].lower()]
        for s in sorted(hits, key=lambda x: x["value"])[:60]:
            print(f"  0x{s['value']:08x} size={s['size']:<6} "
                  f"{'T' if s['thumb'] else 'A'} {s['name']}")
        print(f"共 {len(hits)} 个匹配（符号总数 {len(syms)}）")
        return

    if args.callers:
        if not args.symbol:
            sys.exit("--callers 需要给符号名")
        cand = [x for x in syms if args.symbol == x["name"]] or \
               [x for x in syms if args.symbol in x["name"]]
        if not cand:
            sys.exit(f"没找到符号 {args.symbol}")
        tgt = max(cand, key=lambda x: x["size"])
        print(f"调用 {tgt['name']} (0x{tgt['value']:x}) 的位置：")
        for addr, secname in callers(d, secs, tgt["value"]):
            print(f"  0x{addr:08x}  [{secname}]")
        return

    if args.addr is not None:
        va, size, thumb = args.addr, 0, bool(args.addr & 1)
        name = f"@0x{va:x}"
    else:
        cand = [s for s in syms if args.symbol == s["name"]]
        if not cand:
            cand = [s for s in syms if args.symbol in s["name"]]
        if not cand:
            sys.exit(f"没找到符号 {args.symbol}")
        best = max(cand, key=lambda s: s["size"])
        va, size, thumb = best["value"], best["size"], best["thumb"]
        name = best["name"]

    off = va_to_off(secs, va & ~1)
    n = args.n or max(20, (size // 2) if size else 100)
    print(f"{name}  VA=0x{va:x} file_off=0x{off:x} size={size} "
          f"{'Thumb' if thumb else 'ARM'}")
    code = d[off:off + (size or n * 4)]
    for ins in disasm(code, va & ~1, thumb, n):
        print(f"  0x{ins.address:08x}  {ins.mnemonic:<8} {ins.op_str}")


if __name__ == "__main__":
    main()
