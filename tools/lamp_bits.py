"""indicator_lamp 位定义全表：逐位点亮，从固件日志里读出该位对应的字段名。

原理：`mcucom_rx_indicator_lamp` 会把解析出来的每个布尔字段打进日志
（`indicator_lamp.<字段名> 0/1`）。喂「第 i 位 = 1」的载荷，
对比全 0 载荷的日志，就能把每一位对应到字段名。

用法：python3 tools/lamp_bits.py            # 输出 markdown 表
      python3 tools/lamp_bits.py --json out.json
"""
import argparse
import json
import os
import re
import sys
import time

LAB = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, LAB + '/tools')

from dash_up import Peer, boot_sequence, sync_frame
from cfcp_probe import prop_frame

PROP_LAMP = 0x2170951E
RE = re.compile(r'indicator_lamp\.([A-Za-z_0-9]+) (\d+)')


def log_fields(since):
    with open('/tmp/ui-serial.log', 'rb') as f:
        f.seek(since)
        txt = f.read().decode('utf-8', 'replace')
    out = {}
    for line in txt.splitlines():
        m = RE.search(line)
        if m:
            out[m.group(1)] = int(m.group(2))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--json', default=None)
    ap.add_argument('--settle', type=float, default=0.45)
    args = ap.parse_args()

    p = Peer('127.0.0.1', 9123)
    time.sleep(0.3)
    for f in boot_sequence():
        p.send(f)
    time.sleep(0.35)
    p.pump()
    p.send(sync_frame(True))
    time.sleep(0.4)
    p.pump()

    def probe(payload):
        off = os.path.getsize('/tmp/ui-serial.log')
        p.send(prop_frame(PROP_LAMP, 0, bytes(payload)))
        time.sleep(args.settle)
        p.pump()
        return log_fields(off)

    base = probe([0] * 16)
    print(f"baseline fields: {base}\n")

    table = []
    for byte in range(16):
        for bit in range(8):
            payload = [0] * 16
            payload[byte] = 1 << bit
            cur = probe(payload)
            new = {k: v for k, v in cur.items() if base.get(k, 0) != v}
            if new:
                idx = byte * 8 + bit
                table.append({'bit': idx, 'byte': byte, 'bit_in_byte': bit,
                              'fields': new})
                print(f"bit {idx:3d} (byte{byte} bit{bit}) -> {new}")
            # 复位
            probe([0] * 16)

    print(f"\n共 {len(table)} 个位有语义")
    if args.json:
        with open(args.json, 'w') as f:
            json.dump(table, f, indent=1, ensure_ascii=False)
        print("saved", args.json)
    p.close()


if __name__ == '__main__':
    main()
