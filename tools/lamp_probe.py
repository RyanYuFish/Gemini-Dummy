"""indicator_lamp 位定义探针：逐位点亮，看固件在屏幕上画出的是哪个图标。

indicator_lamp（prop 0x2170951e，16B）是一组位标志。固件收到后会更新顶部的
指示灯区（ABS / TC / 大灯 / 转向 / RADAR …）。本工具：

  1. 先取基线帧；
  2. 依次把 16 字节里的每一位单独置 1，其余清 0，喂进去；
  3. 每次和基线比一遍，统计「变了多少像素、变在哪个矩形」。

输出：bit -> (变化像素数, x0,y0,x1,y1)。据此就能知道固件把哪个 bit 画到了哪。

用法：
    python3 tools/lamp_probe.py                 # 全 128 位
    python3 tools/lamp_probe.py --range 0:32    # 只扫前 32 位
    python3 tools/lamp_probe.py --enter         # 先进 P 档主界面再扫
"""
import argparse
import os
import socket
import struct
import sys
import time

LAB = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, LAB + '/tools')

from dash_up import (Peer, boot_sequence, sync_frame, vi2_frame, vi3_frame, batt_frame,
                     odo_frame, trip_frame, prop_u32, PROP_KL15, PROP_TRIP1, frame_stats)
from cfcp_probe import prop_frame

PROP_LAMP = 0x2170951E


def read_frame():
    p = '/tmp/ui-frame.ppm'
    with open(p, 'rb') as f:
        f.readline()
        wh = f.readline().split()
        w, h = int(wh[0]), int(wh[1])
        f.readline()
        return w, h, f.read()


def diff_bbox(a, b):
    """返回 (变化像素数, x0,y0,x1,y1)；b 是新帧。"""
    w = a[0]
    n = 0
    x0 = y0 = 10 ** 9
    x1 = y1 = -1
    for i in range(0, len(a[2]), 3):
        if a[2][i] != b[2][i] or a[2][i + 1] != b[2][i + 1] or a[2][i + 2] != b[2][i + 2]:
            n += 1
            px = (i // 3) % w
            py = (i // 3) // w
            if px < x0:
                x0 = px
            if px > x1:
                x1 = px
            if py < y0:
                y0 = py
            if py > y1:
                y1 = py
    return n, (x0, y0, x1, y1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--range', default='0:128', help='bit 范围 start:end')
    ap.add_argument('--enter', action='store_true', help='先进 P 档主界面再扫')
    ap.add_argument('--settle', type=float, default=0.35)
    ap.add_argument('--out', default=None, help='把结果写成 json')
    args = ap.parse_args()

    a, b = [int(x) for x in args.range.split(':')]

    p = Peer('127.0.0.1', 9123)
    time.sleep(0.3)
    for f in boot_sequence():
        p.send(f)
    time.sleep(0.35)
    p.pump()
    p.send(sync_frame(True))
    time.sleep(0.4)
    p.pump()

    if args.enter:
        for _ in range(20):
            p.send(vi2_frame(gear=0, remind_milage=0))
            p.send(vi3_frame(drive_mode=1, battery=91))
            p.send(batt_frame(91))
            p.send(odo_frame(5060, 287))
            p.send(trip_frame(PROP_TRIP1, 100, 35))
            time.sleep(0.12)
            p.pump()
        p.send(vi2_frame(gear=1, remind_milage=0))
        t0 = time.time()
        while time.time() - t0 < 8:
            p.pump()
            p.send(prop_u32(PROP_KL15, 0x99))
            p.send(sync_frame(True))
            p.send(vi3_frame(drive_mode=1, battery=91))
            p.send(batt_frame(91))
            p.send(odo_frame(5060, 287))
            p.send(trip_frame(PROP_TRIP1, 100, 35))
            time.sleep(0.2)

    # 基线：全 0
    p.send(prop_frame(PROP_LAMP, 0, bytes(16)))
    time.sleep(0.8)
    p.pump()
    base = read_frame()
    print(f"baseline captured  {base[0]}x{base[1]}  nonblack={frame_stats()[2]:.2f}%")

    results = []
    for bit in range(a, b):
        buf = bytearray(16)
        buf[bit // 8] = 1 << (bit % 8)
        p.send(prop_frame(PROP_LAMP, 0, bytes(buf)))
        time.sleep(args.settle)
        p.pump()
        time.sleep(0.1)
        cur = read_frame()
        n, box = diff_bbox(base, cur)
        if n > 20:
            results.append((bit, n, box))
            print(f"bit {bit:3d} (byte{bit//8} bit{bit%8}) -> {n:6d} px  bbox={box}")
        # 复位
        p.send(prop_frame(PROP_LAMP, 0, bytes(16)))
        time.sleep(0.12)

    print(f"\n{len(results)} 个 bit 有可见效果")
    if args.out:
        import json
        with open(args.out, 'w') as f:
            json.dump([{'bit': b, 'px': n, 'bbox': list(box)} for b, n, box in results], f,
                      indent=1)
        print("saved", args.out)
    p.close()


if __name__ == '__main__':
    main()
