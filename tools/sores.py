#!/usr/bin/env python3
"""ARM32 shared-object disassembler that resolves PLT stubs to symbol names.

The AE5I cluster library is a stripped-ish .so whose internal classes are
exported through .rel.plt/.dynsym, so every `blx 0x7xxxx` is really a call to
a named function.  Decoding the Thumb PLT veneers gives us real call graphs.

Usage:
  python3 sores.py <elf> --list SUBSTR
  python3 sores.py <elf> <symbol|0xVA> [--n N]
  python3 sores.py <elf> --callers <symbol|0xVA>      # direct bl/blx callers
  python3 sores.py <elf> --strings SUBSTR
"""
import argparse
import bisect
import struct
import sys

try:
    from capstone import Cs, CS_ARCH_ARM, CS_MODE_ARM, CS_MODE_THUMB
except ImportError:
    sys.exit("need capstone")


def load(path):
    d = open(path, 'rb').read()
    if d[:4] != b'\x7fELF' or d[4] != 1:
        sys.exit("need 32-bit ELF")
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
    B = {s['name']: s for s in secs}

    # dynsym names
    ds, dstr = B['.dynsym'], B['.dynstr']
    dyn = []
    for i in range(ds['size'] // ds['ent']):
        o = ds['off'] + i * ds['ent']
        nm, val, sz, info, oth, shn = struct.unpack_from('<IIIBBH', d, o)
        e = d.find(b'\x00', dstr['off'] + nm)
        dyn.append((d[dstr['off'] + nm:e].decode('ascii', 'ignore'), val, (info & 0xf), shn))

    # rel.plt -> GOT slot -> symbol name
    got2name = {}
    if '.rel.plt' in B:
        r = B['.rel.plt']
        for i in range(r['size'] // r['ent']):
            o = r['off'] + i * r['ent']
            r_off, r_info = struct.unpack_from('<II', d, o)
            si = r_info >> 8
            if si < len(dyn):
                got2name[r_off] = dyn[si][0]

    def ror(v, r):
        r &= 31
        return ((v >> r) | (v << (32 - r))) & 0xFFFFFFFF if r else v

    # Decode Thumb PLT veneers: add r12,pc,#a ; add r12,r12,#b ; ldr pc,[r12,#c]
    plt2name = {}
    if '.plt' in B:
        plt = B['.plt']
        base, end = plt['addr'], plt['addr'] + plt['size']
        addr = base
        while addr + 12 <= end:
            w1, w2, w3 = struct.unpack_from('<III', d, plt['off'] + (addr - base))
            if (w1 & 0xFFFFF000) == 0xE28FC000 and (w2 & 0xFFFFF000) == 0xE28CC000 \
               and (w3 & 0xFFFFF000) == 0xE5BCF000:
                r12 = (addr + 8) + ror(w1 & 0xFF, ((w1 >> 8) & 0xF) * 2)
                r12 += ror(w2 & 0xFF, ((w2 >> 8) & 0xF) * 2)
                got = r12 + (w3 & 0xFFF)
                nm = got2name.get(got) or got2name.get(got + 4)
                if nm:
                    plt2name[addr] = nm
            addr += 4

    # defined functions (with sizes) for the "enclosing function" lookup
    funcs = {}
    for s in secs:
        if s['typ'] in (2, 11) and s['ent']:
            strtab = secs[s['link']]['off']
            for i in range(s['size'] // s['ent']):
                oo = s['off'] + i * s['ent']
                nm, val, sz, info, oth, shn = struct.unpack_from('<IIIBBH', d, oo)
                if val and (info & 0xf) in (2, 10):
                    e = d.find(b'\x00', strtab + nm)
                    funcs.setdefault(val & ~1, (d[strtab + nm:e].decode('ascii', 'ignore'), sz or 0))
    return d, secs, B, dyn, plt2name, funcs


def resolve(syms, t):
    if t.startswith('0x'):
        return int(t, 16) & ~1
    if t in syms:
        return syms[t] & ~1
    hits = [v for v, (n, s) in syms.items() if n == t]
    if not hits:
        hits = sorted(v for v, (n, s) in syms.items() if t in n)[:1]
    return (hits[0] & ~1) if hits else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('elf')
    ap.add_argument('target', nargs='?')
    ap.add_argument('--n', type=int, default=200)
    ap.add_argument('--list', dest='lst')
    ap.add_argument('--callers')
    ap.add_argument('--strings')
    a = ap.parse_args()
    d, secs, B, dyn, plt, funcs = load(a.elf)

    if a.lst is not None:
        for v, (nm, sz) in sorted(funcs.items()):
            if a.lst.lower() in nm.lower():
                print(f"  {v:#010x} {sz:6d} {nm}")
        return
    if a.strings:
        i = 0
        while True:
            j = d.find(a.strings.encode(), i)
            if j < 0:
                break
            s = max(0, j - 50)
            e = d.find(b'\x00', j)
            ctx = d[s:e]
            print(f"  off={j:#x}: {''.join(chr(c) if 32 <= c < 127 else '.' for c in ctx)}")
            i = j + 1
        return

    addrs = sorted(funcs)
    md = Cs(CS_ARCH_ARM, CS_MODE_THUMB)
    md.skipdata = True

    if a.callers:
        # Resolve the requested name: accept a defined function, a PLT import, or
        # a raw VA.  Accept a bare substring too.
        want = a.callers
        tgt = resolve(funcs, want) if not want.startswith('0x') else None
        names = set()
        if tgt is not None:
            names.add(funcs.get(tgt, ('', 0))[0])
        for _a, nm in plt.items():
            if want == nm or (want in nm):
                names.add(nm)
        if tgt is None:
            tgt = int(want, 16) & ~1
        for s in secs:
            if not (s['fl'] & 0x4) or not s['off']:
                continue
            for ins in md.disasm(d[s['off']:s['off'] + s['size']], s['addr']):
                if ins.mnemonic not in ('bl', 'blx') or not ins.op_str:
                    continue
                try:
                    t = int(ins.op_str.lstrip('#'), 16) & ~1
                except ValueError:
                    continue
                hit = (t == tgt) or (plt.get(t) in names)
                if not hit:
                    continue
                i = bisect.bisect_right(addrs, ins.address) - 1
                owner = funcs[addrs[i]][0] if i >= 0 else '?'
                via = plt.get(t, '')
                print(f"  {ins.address:#010x} -> {via or hex(t)}  in {owner}")
        return

    if not a.target:
        sys.exit("need target")
    va = resolve(funcs, a.target)
    if va is None:
        sys.exit("symbol not found")
    off = None
    for s in secs:
        if s['addr'] <= va < s['addr'] + s['size'] and s['off']:
            off = s['off'] + (va - s['addr'])
            break
    if off is None:
        sys.exit("VA not mapped")
    nm, sz = funcs.get(va, ('', 0))
    print(f"{nm} @ {va:#x} size={sz}")
    cnt = 0
    for ins in md.disasm(d[off:off + a.n * 4], va):
        note = ''
        if ins.mnemonic in ('bl', 'blx') and ins.op_str:
            try:
                t = int(ins.op_str.lstrip('#'), 16) & ~1
            except ValueError:
                t = None
            if t is not None:
                if t in plt:
                    note = '   ; ' + plt[t]
                elif t in funcs:
                    note = '   ; ' + funcs[t][0]
        print(f"  {ins.address:#010x}  {ins.mnemonic:8s} {ins.op_str}{note}")
        cnt += 1
        if cnt >= a.n:
            break


if __name__ == '__main__':
    main()
