#!/usr/bin/env python3
"""CFCP 上行探测台：扮演 MCU 对端（ACK + 喂帧），逐个 prop 试探并回收 guest 日志。

用法:
  python3 cfcp_probe.py --lit                       # 只点亮（KL15）+ 存帧
  python3 cfcp_probe.py --sweep 0x21707400:0x21707420
  python3 cfcp_probe.py --props 0x21707402:val20,0x21707403:val20
  python3 cfcp_probe.py --frame                     # 打印当前帧统计 + 存 PNG

设计要点（逆向结论）：
  * guest 的 0x75 属性帧要求对端 ACK，否则重传 3 次丢弃 → 应用层收不到属性。
  * 探测用「身份载荷」= 第 i 字节 = i，这样 handler 日志里字段值可以直接反推偏移。
"""
import argparse
import os
import socket
import struct
import sys
import threading
import time

MAGIC = b"\xfe\x5a\xaa\xa5"
TAIL = b"\xa5\x55\x5a"
ACK = bytes([0xFE, 0x5A, 0xAA, 0xA5, 0x90, 0x08, 0x55, 0x01, 0x01, 0x00, 0x00, 0x00, 0x10, 0xA5, 0x55, 0x5A])
LOG = "/tmp/ui-serial.log"


def build(f0, f1, cmd, data):
    body = bytearray([f0 & 0xFF, f1 & 0xFF])
    body += cmd.to_bytes(4, "little")
    body += len(data).to_bytes(2, "little")
    body += bytes(data)
    return MAGIC + bytes(body) + bytes([(~sum(body)) & 0xFF]) + TAIL


def prop_frame(prop, sub, value):
    inner = 4 + 4 + len(value)
    data = struct.pack("<HH", inner, prop & 0xFFFF)
    data += struct.pack("<H", (prop >> 16) & 0xFFFF)
    data += struct.pack("<I", sub & 0xFFFFFFFF)
    data += bytes(value)
    return build(0x11, 0x02, 0x00010175, data)


class Peer:
    def __init__(self, host="127.0.0.1", port=9123):
        self.s = socket.create_connection((host, port), timeout=5)
        self.s.setblocking(False)
        self.stop = False
        self.acks = 0
        self.got = 0
        self.t = threading.Thread(target=self._rx, daemon=True)
        self.t.start()

    def _rx(self):
        buf = b""
        while not self.stop:
            try:
                c = self.s.recv(16384)
            except (BlockingIOError, socket.timeout):
                time.sleep(0.005)
                continue
            except OSError:
                break
            if not c:
                break
            buf += c
            self.got += len(c)
            while True:
                i = buf.find(MAGIC)
                if i < 0:
                    break
                j = buf.find(TAIL, i)
                if j < 0:
                    break
                buf = buf[j + 3:]
                try:
                    self.s.sendall(ACK)
                    self.acks += 1
                except OSError:
                    pass

    def send(self, frame):
        try:
            self.s.sendall(frame)
            return True
        except OSError:
            return False

    def close(self):
        self.stop = True
        time.sleep(0.05)
        try:
            self.s.close()
        except OSError:
            pass


def baseline(kl15=0x99, speed=0, rpm=0, temp=0, gear=(8, 0)):
    out = [
        prop_frame(0x21701002, 0, b"SW.1.00.56 AE5I".ljust(24, b"\x00")),
        prop_frame(0x21417310, 0, struct.pack("<I", 1)),
        prop_frame(0x27407404, 0, struct.pack("<I", 0xFFFFFFFF)),
        prop_frame(0x21707701, 0, struct.pack("<I", 0xC0)),
        prop_frame(0x21709702, 0, bytes(gear)),
        prop_frame(0x21709521, 0, struct.pack("<I", 0)),
        prop_frame(0x21407072, 0, struct.pack("<I", 0)),
        prop_frame(0x21400030, 0, struct.pack("<I", kl15)),
    ]
    vi1 = bytearray(20)
    struct.pack_into("<i", vi1, 0, speed)
    struct.pack_into("<i", vi1, 12, rpm)
    struct.pack_into("<i", vi1, 16, temp)
    out.append(prop_frame(0x21707402, 0, vi1))
    return out


def logoff():
    try:
        return os.path.getsize(LOG)
    except OSError:
        return 0


def newlines(off, maxlines=40):
    try:
        with open(LOG, 'rb') as f:
            f.seek(off)
            d = f.read()
    except OSError:
        return []
    txt = d.decode('utf-8', 'replace')
    lines = [ln for ln in txt.splitlines() if ln.strip()]
    return lines[-maxlines:]


def frame_stats(png=None):
    p = '/tmp/ui-frame.ppm'
    if not os.path.exists(p):
        return None
    with open(p, 'rb') as f:
        f.readline()
        wh = f.readline().split()
        w, h = int(wh[0]), int(wh[1])
        f.readline()
        d = f.read()
    n = w * h
    nb = sum(1 for i in range(n) if d[i * 3] + d[i * 3 + 1] + d[i * 3 + 2] > 10)
    teal = sum(1 for i in range(n) if d[i * 3 + 1] >= d[i * 3] and d[i * 3 + 2] >= d[i * 3]
               and (d[i * 3 + 1] + d[i * 3 + 2]) > 40)
    if png:
        try:
            from PIL import Image
            Image.open(p).convert('RGB').save(png)
        except Exception as e:
            print("png fail:", e)
    return w, h, 100.0 * nb / n, 100.0 * teal / n


def parse_spec(s):
    """0x21707400:0x21707420 / 0x21707402:val20 / 0x21707404:zeros16"""
    prop, _, kind = s.partition(':')
    return int(prop, 16), (kind or 'val20')


def payload_for(kind, i=0):
    if kind.startswith('val'):
        n = int(kind[3:]) if len(kind) > 3 else 20
        return bytes([(i + k) & 0xFF for k in range(n)])
    if kind.startswith('zeros'):
        n = int(kind[5:]) if len(kind) > 5 else 20
        return bytes(n)
    if kind.startswith('gear'):
        v = int(kind[4:])
        b = bytearray(20)
        for off in (0, 4, 8, 12, 16):
            struct.pack_into('<i', b, off, v)
        return bytes(b)
    return bytes(range(20))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--lit', action='store_true')
    ap.add_argument('--sweep', help='0xSTART:0xEND')
    ap.add_argument('--props', help='comma separated prop:kind')
    ap.add_argument('--frame', action='store_true')
    ap.add_argument('--png', default=None)
    ap.add_argument('--gear', type=int, default=None, help='feed gear via 0x21709702')
    ap.add_argument('--wait', type=float, default=0.45, help='per-prop wait (s)')
    args = ap.parse_args()

    if args.frame:
        st = frame_stats(args.png)
        print(f"frame {st[0]}x{st[1]} nonblack={st[2]:.2f}% teal={st[3]:.2f}%")
        return

    p = Peer()
    time.sleep(0.3)
    for f in baseline():
        p.send(f)
    time.sleep(0.6)

    if args.lit:
        time.sleep(1.0)
        st = frame_stats(args.png)
        if st:
            print(f"after lit: nonblack={st[2]:.2f}% teal={st[3]:.2f}%")

    cands = []
    if args.sweep:
        a, b = args.sweep.split(':')
        for v in range(int(a, 16), int(b, 16) + 1):
            cands.append((v, 'val20'))
    if args.props:
        for s in args.props.split(','):
            cands.append(parse_spec(s))

    for i, (prop, kind) in enumerate(cands):
        off = logoff()
        p.send(prop_frame(prop, 0, payload_for(kind, i)))
        time.sleep(args.wait)
        lines = newlines(off)
        keep = [ln for ln in lines if any(k in ln for k in
                ('vehicle_info', 'gear', 'mcucom', 'setitem', 'trip', 'lamp', 'battery',
                 'weather', 'KL15', 'PFC', 'Animation', 'Scene', 'sence', 'opacity'))]
        tag = 'HIT' if keep else '   '
        print(f"[{tag}] {prop:#010x} {kind:8s} +{len(lines)} lines")
        for ln in keep[:6]:
            print("      ", ln[:200])
        if keep:
            st = frame_stats()
            if st:
                print(f"      frame nonblack={st[2]:.2f}% teal={st[3]:.2f}%")

    if args.png:
        frame_stats(args.png)
    print(f"acks={p.acks} rx_bytes={p.got}")
    p.close()


if __name__ == '__main__':
    main()
