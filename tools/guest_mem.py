#!/usr/bin/env python3
"""按需 dump 客端物理内存并搜索字节模式（走 QEMU monitor unix socket）。

用途：把一段**唯一标记**发进 guest，再 dump RAM 搜它，定位数据被写到哪
（例如 ride-info 结构体在 App 对象里的落点）。

用法：
  python3 Gemini-Dummy/tools/guest_mem.py dump            # dump 到 /tmp/guest_ram.bin
  python3 Gemini-Dummy/tools/guest_mem.py find A1A2A3A4   # 在已有 dump 里搜
  python3 Gemini-Dummy/tools/guest_mem.py dumpfind A1A2A3A4

monitor 注意：`pmemsave` 的文件名**必须加引号**，否则会被当表达式解析并报
"invalid char 't' in expression"。
"""
import argparse
import os
import socket
import time

MON = "/tmp/ui-mon.sock"
DUMP = "/tmp/guest_ram.bin"


def hmp(cmd, wait=0.6, sock_path=MON):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(sock_path)
    s.settimeout(10)
    time.sleep(0.15)
    try:
        s.settimeout(0.3)
        s.recv(65536)
    except OSError:
        pass
    s.sendall(cmd.encode() + b"\r")
    time.sleep(wait)
    out = b""
    end = time.time() + 1.0
    while time.time() < end:
        try:
            s.settimeout(0.3)
            chunk = s.recv(65536)
            if not chunk:
                break
            out += chunk
        except OSError:
            break
    s.close()
    return out.decode("utf-8", "replace")


def dump(path, size=0x10000000):
    """一次性 pmemsave 整段（文件名必须加引号）。"""
    if os.path.exists(path):
        os.remove(path)
    hmp(f'pmemsave 0 0x{size:x} "{path}"', wait=0.3)
    deadline = time.time() + 180
    while time.time() < deadline:
        if os.path.exists(path) and os.path.getsize(path) >= size:
            return os.path.getsize(path)
        time.sleep(0.5)
    return os.path.getsize(path) if os.path.exists(path) else 0


def find(path, pattern, limit=20):
    pat = bytes.fromhex(pattern.replace(" ", ""))
    hits = []
    with open(path, "rb") as f:
        prev = b""
        off = 0
        CH = 8 << 20
        while True:
            blk = f.read(CH)
            if not blk:
                break
            data = prev + blk
            base = off - len(prev)
            i = 0
            while True:
                i = data.find(pat, i)
                if i < 0:
                    break
                hits.append(base + i)
                if len(hits) >= limit:
                    return hits
                i += 1
            prev = data[-len(pat):]
            off += len(blk)
    return hits


def diff(a, b, ctx=16, limit=60):
    """比较两份 dump，输出变化区间（按 16B 聚合）。"""
    da = open(a, "rb").read()
    db = open(b, "rb").read()
    n = min(len(da), len(db))
    runs = []
    i = 0
    STEP = 16
    while i < n:
        if da[i:i + STEP] != db[i:i + STEP]:
            start = i
            last = i
            while i < n:
                if da[i:i + STEP] != db[i:i + STEP]:
                    last = i
                    i += STEP
                else:
                    break
            runs.append((start, last + STEP))
        i += STEP
    print(f"变化区间 {len(runs)} 段（共 {n:#x} 字节）")
    for start, end in runs[:limit]:
        print(f"  PA 0x{start:08x}..0x{end:08x}  ({end-start} B)")
        print(f"      A: {da[start:min(end,start+ctx)].hex(' ')}")
        print(f"      B: {db[start:min(end,start+ctx)].hex(' ')}")
    if len(runs) > limit:
        print(f"  …还有 {len(runs)-limit} 段")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["dump", "find", "dumpfind", "hexdump", "diff"])
    ap.add_argument("pattern", nargs="?", default="")
    ap.add_argument("--path", default=DUMP)
    ap.add_argument("--size", type=lambda x: int(x, 0), default=0x10000000)
    ap.add_argument("--other", default="/tmp/guest_ram2.bin")
    args = ap.parse_args()

    if args.mode in ("dump", "dumpfind"):
        t0 = time.time()
        n = dump(args.path, args.size)
        print(f"dump {n:#x} 字节，用时 {time.time()-t0:.1f}s")
    if args.mode in ("find", "dumpfind"):
        hits = find(args.path, args.pattern)
        print(f"命中 {len(hits)} 处：")
        for h in hits:
            print(f"  PA 0x{h:08x}")
        return
    if args.mode == "diff":
        diff(args.path, args.other)
        return
    if args.mode == "hexdump":
        off = int(args.pattern, 0)
        with open(args.path, "rb") as f:
            f.seek(off)
            d = f.read(256)
        for i in range(0, len(d), 16):
            row = d[i:i + 16]
            asc = "".join(chr(b) if 32 <= b < 127 else "." for b in row)
            print(f"{off+i:08x}  {row.hex(' '):<47}  {asc}")


if __name__ == "__main__":
    main()
