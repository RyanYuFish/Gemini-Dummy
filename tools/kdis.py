#!/usr/bin/env python3
"""Disassemble an ARM32 Linux kernel ELF (from vmlinux-to-elf) by symbol name or
VA, mapping kernel VA -> file offset via PT_LOAD program headers.

Usage:
  python3 kdis.py <elf> <symbol|0xVA> [--n N] [--arm]
  python3 kdis.py <elf> --list SUBSTR         # list symbols containing SUBSTR
  python3 kdis.py <elf> --callers SYMBOL      # find direct bl/blx to SYMBOL
  python3 kdis.py <elf> --imm ADDR            # find movw/movt/mov pairs building ADDR
"""
import argparse, struct, sys

try:
    from capstone import Cs, CS_ARCH_ARM, CS_MODE_ARM, CS_MODE_THUMB
except ImportError:
    sys.exit("需要 capstone：pip install capstone")


def parse(path):
    d = open(path, 'rb').read()
    if d[:4] != b'\x7fELF' or d[4] != 1:
        sys.exit("需要 32 位 ELF")
    e_phoff = struct.unpack_from('<I', d, 0x1c)[0]
    e_phentsize = struct.unpack_from('<H', d, 0x2a)[0]
    e_phnum = struct.unpack_from('<H', d, 0x2c)[0]
    e_shoff = struct.unpack_from('<I', d, 0x20)[0]
    e_shentsize = struct.unpack_from('<H', d, 0x2e)[0]
    e_shnum = struct.unpack_from('<H', d, 0x30)[0]
    segs = []
    for i in range(e_phnum):
        o = e_phoff + i * e_phentsize
        p_type, p_offset, p_vaddr, p_paddr, p_filesz, p_memsz, p_flags, p_align = \
            struct.unpack_from('<IIIIIIII', d, o)
        if p_type == 1 and p_filesz:
            segs.append((p_vaddr, p_offset, p_filesz))
    syms = {}
    sizes = {}
    for i in range(e_shnum):
        o = e_shoff + i * e_shentsize
        _, typ, _, _, off, size, link, _, _, entsz = struct.unpack_from('<IIIIIIIIII', d, o)
        if typ in (2, 11) and entsz:
            stroff = struct.unpack_from('<I', d, e_shoff + link * e_shentsize + 0x10)[0]
            for k in range(size // entsz):
                oo = off + k * entsz
                nm, val, sz, info, oth, shn = struct.unpack_from('<IIIBBH', d, oo)
                if val:
                    e = d.find(b'\x00', stroff + nm)
                    name = d[stroff + nm:e].decode('ascii', 'ignore')
                    syms.setdefault(val, name)
                    if sz:
                        sizes[val] = sz
    return d, segs, syms, sizes


def va2off(segs, va):
    for v, o, s in segs:
        if v <= va < v + s:
            return o + (va - v)
    return None


def text_ranges(segs):
    """Exclude the .data segment (writable) so we only scan code."""
    return [(v, o, s) for v, o, s in segs]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('elf'); ap.add_argument('target', nargs='?')
    ap.add_argument('--n', type=int, default=200)
    ap.add_argument('--arm', action='store_true')
    ap.add_argument('--list', dest='lst')
    ap.add_argument('--callers')
    ap.add_argument('--imm')
    a = ap.parse_args()
    d, segs, syms, sizes = parse(a.elf)

    if a.lst is not None:
        for v, nm in sorted(syms.items()):
            if a.lst.lower() in nm.lower():
                print(f"  {v:#010x} {nm}")
        return

    def resolve(t):
        if t.startswith('0x'):
            return int(t, 16) & ~1
        if t in syms:
            return syms[t] if isinstance(syms, dict) else None
        hits = [v for v, n in syms.items() if n == t]
        if not hits:
            hits = sorted(v for v, n in syms.items() if t in n)[:1]
        return (hits[0] & ~1) if hits else None

    if a.callers:
        tgt = resolve(a.callers)
        if tgt is None:
            sys.exit(f"symbol {a.callers} not found")
        md = Cs(CS_ARCH_ARM, CS_MODE_THUMB); md.skipdata = True
        found = 0
        for v, o, s in segs:
            for ins in md.disasm(d[o:o + s], v):
                if ins.mnemonic in ('bl', 'blx') and ins.op_str:
                    try:
                        t = int(ins.op_str, 16)
                    except ValueError:
                        continue
                    if (t & ~1) == tgt:
                        print(f"  caller@ {ins.address:#010x} -> {a.callers}({tgt:#x})")
                        found += 1
        print(f"-- {found} direct callers --")
        return

    if a.imm:
        want = int(a.imm, 16) & 0xFFFFFFFF
        lo = want & 0xFFFF
        hi = (want >> 16) & 0xFFFF
        md = Cs(CS_ARCH_ARM, CS_MODE_THUMB); md.skipdata = True
        for v, o, s in segs:
            regs = {}
            for ins in md.disasm(d[o:o + s], v):
                if ins.mnemonic in ('movw', 'mov') and ins.op_str.count(',') == 1:
                    parts = ins.op_str.split(',')
                    try:
                        im = int(parts[1].strip().lstrip('#'), 0)
                    except ValueError:
                        continue
                    if im == lo:
                        regs[parts[0].strip()] = ('lo', ins.address)
                elif ins.mnemonic == 'movt' and ins.op_str.count(',') == 1:
                    parts = ins.op_str.split(',')
                    try:
                        im = int(parts[1].strip().lstrip('#'), 0)
                    except ValueError:
                        continue
                    r = parts[0].strip()
                    if im == hi and r in regs and regs[r][0] == 'lo':
                        print(f"  builds {want:#010x} at {regs[r][1]:#010x}..{ins.address:#010x} ({r})")
        return

    if not a.target:
        sys.exit("need target")

    va = resolve(a.target)
    if va is None:
        sys.exit(f"symbol {a.target} not found")
    off = va2off(segs, va & ~1)
    if off is None:
        sys.exit(f"VA {va:#x} not in any PT_LOAD")
    mode = CS_MODE_ARM if a.arm else CS_MODE_THUMB
    md = Cs(CS_ARCH_ARM, mode); md.skipdata = True
    nm = syms.get(va & ~1, '')
    print(f"{a.target} ({nm}) VA={va:#x} file_off={off:#x} {'ARM' if a.arm else 'Thumb'} size={sizes.get(va & ~1, 0)}")
    cnt = 0
    for ins in md.disasm(d[off:off + a.n * 4], va & ~1):
        print(f"  {ins.address:#010x}  {ins.mnemonic:8s} {ins.op_str}")
        cnt += 1
        if cnt >= a.n:
            break


if __name__ == '__main__':
    main()
