#!/usr/bin/env python3
"""Find direct bl/blx callers of a target address inside an ARM32 ELF (.so or exe).

Usage:
  python3 xcaller.py <elf> <0xTARGET> [--mode thumb|arm]

Prints caller instruction addresses plus the enclosing function symbol (if any).
"""
import sys, struct, bisect

try:
    from capstone import Cs, CS_ARCH_ARM, CS_MODE_THUMB, CS_MODE_ARM
except ImportError:
    sys.exit("need capstone")


def load(path):
    d = open(path, 'rb').read()
    e_shoff = struct.unpack_from('<I', d, 0x20)[0]
    es = struct.unpack_from('<H', d, 0x2e)[0]
    n = struct.unpack_from('<H', d, 0x30)[0]
    shstr = struct.unpack_from('<H', d, 0x32)[0]
    secs = []
    for k in range(n):
        o = e_shoff + k * es
        nm, typ, fl, addr, off, size, link, info, al, ent = struct.unpack_from('<IIIIIIIIII', d, o)
        secs.append(dict(nm=nm, typ=typ, fl=fl, addr=addr, off=off, size=size, link=link, ent=ent))
    stroff = secs[shstr]['off']
    for s in secs:
        e = d.find(b'\x00', stroff + s['nm'])
        s['name'] = d[stroff + s['nm']:e].decode()
    syms = {}
    for s in secs:
        if s['typ'] in (2, 11) and s['ent']:
            strtab = secs[s['link']]['off']
            for i in range(s['size'] // s['ent']):
                oo = s['off'] + i * s['ent']
                nm, val, sz, info, oth, shn = struct.unpack_from('<IIIBBH', d, oo)
                if val and (info & 0xf) in (2, 10):  # FUNC / GNU_IFUNC
                    e = d.find(b'\x00', strtab + nm)
                    syms.setdefault(val & ~1, d[strtab + nm:e].decode('ascii', 'ignore'))
    return d, secs, syms


def main():
    path = sys.argv[1]
    tgt = int(sys.argv[2], 16) & ~1
    mode = CS_MODE_THUMB
    if '--mode' in sys.argv:
        if sys.argv[sys.argv.index('--mode') + 1] == 'arm':
            mode = CS_MODE_ARM
    d, secs, syms = load(path)
    addrs = sorted(syms)
    md = Cs(CS_ARCH_ARM, mode)
    md.skipdata = True
    for s in secs:
        if not (s['fl'] & 0x4) or s['off'] == 0 or s['size'] == 0:  # SHF_EXECINSTR
            continue
        for ins in md.disasm(d[s['off']:s['off'] + s['size']], s['addr']):
            if ins.mnemonic in ('bl', 'blx', 'b', 'b.w', 'bx') and ins.op_str:
                try:
                    t = int(ins.op_str, 16)
                except ValueError:
                    continue
                if (t & ~1) == tgt:
                    # enclosing symbol
                    i = bisect.bisect_right(addrs, ins.address) - 1
                    owner = syms[addrs[i]] if i >= 0 else '?'
                    print(f"  {ins.address:#010x} {ins.mnemonic:4s} -> {tgt:#x}   in {addrs[i]:#x} {owner}")
    print("-- done --")


if __name__ == '__main__':
    main()
