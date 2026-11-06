#!/usr/bin/env python3
"""Probe the firmware's NATIVE password UI (PasswordUL) over CFCP.

Reverse-engineered chain (libmcucommodule.so / libdashclustoractivity.so):
  * MCU -> SoC prop 0x21709701, 6 bytes:
        [0..3] password digits (ASCII), [4] status bits, [5] 0
        bit6 (0x40) = power_on_passwd.gointo_passwd_ui
        -> MCUCOM_SIGNAL_POWER_ON_PASSWD_GO_INTO_UI -> BaseWidget::slots_password_ui(1)
        -> ShowPasswordUI() -> PasswordULFB70 (AE5I) / PasswordULAE4
        bit4 (0x10) = check_passwd_success
        bit3 (0x08) = tryNumber_error_lock_notify
        bit5 (0x20) = shutdown_notify
  * SoC -> MCU prop 0x21709701 (mcucom_tx_power_on_passwd):
        same 6 bytes with the 4 entered digits; bit4 set again by
        PasswordUL::mcuStart() after a successful verification.

This script is a diagnostic; the production peers live in tools/dash_up.py
and flutter_app/lib/emu/dash_up.dart.
"""
import argparse
import os
import socket
import struct
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dash_up as D  # noqa: E402
from cfcp_key import key_frame  # noqa: E402

MAGIC = D.MAGIC
TAIL = D.TAIL
ACK = D.ACK


def parse_frames(buf):
    """Yield (frame, prop_id, payload) for complete frames; return leftover."""
    out = []
    while True:
        i = buf.find(MAGIC)
        if i < 0:
            return out, b""
        j = buf.find(TAIL, i)
        if j < 0:
            return out, buf[i:]
        frame = buf[i:j + 3]
        buf = buf[j + 3:]
        prop = None
        payload = b""
        try:
            if len(frame) >= 16 and frame[4] in (0x11, 0x91):
                n = struct.unpack_from('<H', frame, 10)[0]
                data = frame[12:12 + n]
                if len(data) >= 8:
                    lo, hi = struct.unpack_from('<HH', data, 2)
                    prop = lo | (hi << 16)
                    payload = data[8:]
        except (struct.error, IndexError):
            pass
        out.append((frame, prop, payload))
    return out, buf


class ProbePeer:
    def __init__(self, host, port):
        self.s = socket.create_connection((host, port), timeout=5)
        self.s.setblocking(False)
        self.buf = b""
        self.acks = 0
        self.seen = []

    def pump(self, verbose=True):
        try:
            chunk = self.s.recv(65536)
        except (BlockingIOError, socket.timeout, OSError):
            return
        if not chunk:
            return
        self.buf += chunk
        frames, self.buf = parse_frames(self.buf)
        if frames:
            try:
                self.s.sendall(ACK * len(frames))
                self.acks += len(frames)
            except OSError:
                pass
        for _, prop, payload in frames:
            if prop is None:
                continue
            rec = (prop, bytes(payload))
            if rec not in self.seen:
                self.seen.append(rec)
                if verbose:
                    print(f'  <- SoC prop=0x{prop:08x} len={len(payload)} '
                          f'data={payload.hex()}', flush=True)

    def send(self, f):
        try:
            self.s.sendall(f)
        except OSError:
            pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--duration', type=float, default=70)
    ap.add_argument('--prop', type=lambda s: int(s, 0), default=0x21709701)
    ap.add_argument('--bits', type=lambda s: int(s, 0), default=0x40)
    ap.add_argument('--delay', type=float, default=25, help='等待 App 首屏的秒数')
    ap.add_argument('--unlock', action='store_true',
                    help='先按 §41 三段式点亮 P 档主界面，再请求密码 UI')
    ap.add_argument('--toggle', action='store_true',
                    help='先写 0 再写目标位，重复 3 次（位变化才发信号）')
    ap.add_argument('--keys', action='store_true',
                    help='请求 UI 后发送上/下/SET/BACK 键，看固件是否接管按键')
    ap.add_argument('--png', default='/tmp/pw_probe.png')
    a = ap.parse_args()

    p = ProbePeer('127.0.0.1', 9123)
    payload = bytes([0, 0, 0, 0, a.bits & 0xFF, 0])
    print(f'[probe] prop=0x{a.prop:08x} payload={payload.hex()}', flush=True)

    t0 = time.time()
    for f in D.boot_sequence(0x99):
        p.send(f)
    p.pump()
    # Wait for the firmware's first painted frame (same pre-arm rule as dash_up.py).
    while time.time() - t0 < a.delay:
        st = D.frame_stats()
        if st and st[2] > 3.0:
            break
        p.pump()
        p.send(D.prop_u32(D.PROP_KL15, 0x99))
        time.sleep(0.2)
    print(f'[probe] first frame at {time.time()-t0:.1f}s: {D.frame_stats()}', flush=True)

    # Baseline data WITHOUT the unlock notification: stay on the standby page.
    for _ in range(20):
        p.send(D.vi2_frame(gear=0))
        p.send(D.vi1_frame())
        p.send(D.vi3_frame(drive_mode=1, battery=91))
        p.send(D.batt_frame(91))
        p.pump()
        time.sleep(0.15)
    time.sleep(0.5)
    p.pump()
    print(f'[probe] before GO_INTO_UI: {D.frame_stats()}', flush=True)

    if a.unlock:
        p.send(D.sync_frame(True))
        for _ in range(20):
            p.send(D.vi2_frame(gear=0))
            p.send(D.vi1_frame())
            p.send(D.vi3_frame(drive_mode=1, battery=91))
            p.send(D.batt_frame(91))
            p.pump()
            time.sleep(0.12)
        p.send(D.vi2_frame(gear=1))
        time.sleep(3.0)
        p.pump()
        print(f'[probe] P 档主界面: {D.frame_stats()}', flush=True)

    p.send(D.prop_frame(a.prop, 0, bytes([0, 0, 0, 0, 0, 0])))
    time.sleep(0.2)
    p.pump()
    for k in range(3 if a.toggle else 1):
        p.send(D.prop_frame(a.prop, 0, payload))
        time.sleep(0.3)
        p.pump()
        if a.toggle:
            p.send(D.prop_frame(a.prop, 0, bytes(6)))
            time.sleep(0.2)
            p.pump()
        print(f'[probe] GO_INTO_UI #{k + 1}: {D.frame_stats()}', flush=True)
    print('[probe] sent GO_INTO_UI', flush=True)
    time.sleep(1.0)
    p.pump()
    print(f'[probe] after 1s: {D.frame_stats()}', flush=True)

    if a.keys:
        for name, key_id in (('up', 0xD2), ('down', 0xD3), ('SET', 0xD4),
                             ('BACK', 0xD5)):
            p.send(key_frame(key_id, True))
            time.sleep(0.12)
            p.pump()
            p.send(key_frame(key_id, False))
            time.sleep(0.3)
            p.pump()
            print(f'[probe] key {name}: {D.frame_stats()}', flush=True)

    start = time.time()
    last = 0.0
    while time.time() - start < a.duration:
        p.pump()
        now = time.time()
        if now - last > 0.5:
            p.send(D.prop_u32(D.PROP_KL15, 0x99))
            p.send(D.prop_u32(D.PROP_HEARTBEAT, 0))
            p.send(D.vi1_frame())
            p.send(D.vi3_frame(drive_mode=1, battery=91))
            p.send(D.batt_frame(91))
            last = now
        time.sleep(0.02)
    print(f'[probe] final: {D.frame_stats()}  acks={p.acks}', flush=True)
    print(f'[probe] distinct SoC props: {[hex(x[0]) for x in p.seen]}', flush=True)
    if a.png:
        try:
            from PIL import Image
            Image.open('/tmp/ui-frame.ppm').convert('RGB').save(a.png)
            print('[probe] saved', a.png, flush=True)
        except Exception as e:
            print('[probe] png failed', e, flush=True)


if __name__ == '__main__':
    main()
