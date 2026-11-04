#!/usr/bin/env python3
"""批量扫 CFCP 上行帧组合，用「RAM 签名」判定是否被 App 真正解析。

判据
----
`mcucom_rx_ride_info_update` 命中时会把 **33 字节**（不含 2B 标签 CF01）拷进对象成员。
所以给每个组合一个**唯一的标记字节**，全部发完后 dump 一次 RAM，搜
「33 个同值字节、且前两字节不是 CF 01」的连续段：
  * 命中 → 该组合真的被解析（不是仅仅被缓存）；
  * 只有 `CF01 + 33 字节` 原样副本 → 只是缓存，没进对象。

用法：
  python3 Gemini-Dummy/tools/mcufeed_sweep.py            # 默认组合集
  python3 Gemini-Dummy/tools/mcufeed_sweep.py --frame1 0x08
"""
import argparse
import socket
import time

MAGIC = bytes([0xFE, 0x5A, 0xAA, 0xA5])
TAIL = bytes([0xA5, 0x55, 0x5A])
CMD_BASE = 0x00010100

# 落点属性：先按 setItem3 / setItem4 / 无包裹三种试
PROP_CANDIDATES = (0x21709303, 0x21707073, None)


def build(f0, f1, cmd, data):
    body = bytearray([f0 & 0xFF, f1 & 0xFF])
    body += cmd.to_bytes(4, "little")
    body += len(data).to_bytes(2, "little")
    body += data
    return MAGIC + bytes(body) + bytes([(~sum(body)) & 0xFF]) + TAIL


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=9123)
    ap.add_argument("--frame1", type=lambda x: int(x, 0), default=0x02)
    ap.add_argument("--gap", type=float, default=0.03)
    ap.add_argument("--path0", default="/tmp/ram0.bin")
    ap.add_argument("--path1", default="/tmp/ram1.bin")
    args = ap.parse_args()

    combos = []
    i = 0
    for f0 in (0x11, 0x21, 0x31, 0x41):
        for cmdb in (0x75, 0x70, 0x71, 0x72, 0x74, 0x76, 0x55):
            for prop in PROP_CANDIDATES:
                mark = 0x40 + i
                if mark > 0xEF:
                    break
                combos.append((f0, cmdb, prop, mark))
                i += 1
    print(f"组合数 {len(combos)}")

    import subprocess
    subprocess.run(["python3", "Gemini-Dummy/tools/guest_mem.py", "dump",
                    "--path", args.path0], capture_output=True)

    s = socket.create_connection(("127.0.0.1", args.port), timeout=5)
    s.settimeout(0.2)
    for f0, cmdb, prop, mark in combos:
        tlv = b"\xCF\x01" + bytes([mark] * 33)
        if prop is None:
            data = tlv
        else:
            inner = 8 + len(tlv)
            data = (bytes([inner & 0xFF, inner >> 8])
                    + prop.to_bytes(4, "little") + b"\0\0\0\0" + tlv)
        s.sendall(build(f0, args.frame1, CMD_BASE | cmdb, data))
        time.sleep(args.gap)
    time.sleep(1.0)
    try:
        while True:
            s.recv(4096)
    except OSError:
        pass
    s.close()

    subprocess.run(["python3", "Gemini-Dummy/tools/guest_mem.py", "dump",
                    "--path", args.path1], capture_output=True)

    A = open(args.path0, "rb").read()
    B = open(args.path1, "rb").read()
    found = {}
    for f0, cmdb, prop, mark in combos:
        pat = bytes([mark]) * 33
        i = 0
        while True:
            i = B.find(pat, i)
            if i < 0:
                break
            pre = B[i - 2:i]
            if pre != b"\xCF\x01" and A[i:i + 33] != pat:
                found.setdefault(mark, []).append(i)
            i += 1

    print("命中标记：")
    if not found:
        print("  （无）—— 没有任何组合把 33 字节送进对象（都只是缓存）")
    for f0, cmdb, prop, mark in combos:
        if mark in found:
            p = "raw" if prop is None else f"0x{prop:08x}"
            print(f"  f0=0x{f0:02x} cmd=0x{cmdb:02x} prop={p} "
                  f"marker=0x{mark:02x} -> PA {[hex(x) for x in found[mark][:6]]}")


if __name__ == "__main__":
    main()
