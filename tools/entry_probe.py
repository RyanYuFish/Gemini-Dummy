"""进场序列实验台：从冷启动开始，按不同策略进场，抓图并统计残影。

用法：
    python3 tools/entry_probe.py --mode single      # 只写一次挡位
    python3 tools/entry_probe.py --mode early       # 开机即喂（在 Launcher init 前）
    python3 tools/entry_probe.py --mode dual        # 一轮 gear0->gear1
    python3 tools/entry_probe.py --mode quad        # 两轮 gear0->gear1

每次都：杀 QEMU -> 冷启动 -> 按策略喂 -> 等稳 -> 存 /tmp/entry_<mode>.png。
统计指标：非黑%、茶青%，以及「残影分数」（离群小块数量）。
"""
import argparse
import os
import socket
import subprocess
import sys
import time

LAB = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, LAB + '/tools')

from dash_up import (Peer, boot_sequence, sync_frame, vi2_frame, vi1_frame, vi3_frame,
                     batt_frame, odo_frame, trip_frame, prop_u32, PROP_KL15, PROP_TRIP1,
                     frame_stats)


def wait_port(timeout=30):
    t0 = time.time()
    while time.time() - t0 < timeout:
        s = socket.socket()
        s.settimeout(0.4)
        try:
            s.connect(('127.0.0.1', 9123))
            s.close()
            return True
        except OSError:
            s.close()
            time.sleep(0.3)
    return False


def boot():
    subprocess.run(['pkill', '-9', '-f', 'qemu-system-arm'],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(0.8)
    subprocess.Popen(['bash', LAB + '/run_ui.sh'],
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                     start_new_session=True)
    return wait_port()


DATA = dict(speed=0, rpm=0, temp=0, soc=91, odo=5060, avg_power=287,
            trip=100, trip_power=35, drive_mode=1, gear=1, rng=0)


def push_data(p, gear=None):
    p.send(vi1_frame(DATA['speed'], 0, DATA['rpm'], DATA['temp']))
    p.send(vi3_frame(drive_mode=DATA['drive_mode'], battery=DATA['soc']))
    p.send(batt_frame(DATA['soc']))
    p.send(odo_frame(DATA['odo'], DATA['avg_power']))
    p.send(trip_frame(PROP_TRIP1, DATA['trip'], DATA['trip_power']))
    if gear is not None:
        p.send(vi2_frame(gear=gear, remind_milage=DATA['rng']))


def keep(p, sec, gear=None):
    t0 = time.time()
    while time.time() - t0 < sec:
        p.pump()
        p.send(prop_u32(PROP_KL15, 0x99))
        p.send(sync_frame(True))
        push_data(p, gear)
        time.sleep(0.2)


def run(mode):
    assert boot(), 'emulator did not come up'
    t_conn = time.time()
    p = Peer('127.0.0.1', 9123)

    if mode == 'early':
        # 趁 Launcher 还没 init，先把解锁 + 挡位灌进去
        for f in boot_sequence():
            p.send(f)
        time.sleep(0.2)
        p.pump()
        while time.time() - t_conn < 30:
            p.pump()
            p.send(prop_u32(PROP_KL15, 0x99))
            p.send(sync_frame(True))
            push_data(p, DATA['gear'])
            time.sleep(0.15)
        keep(p, 8)
    else:
        # 等 Launcher 画完第一屏
        for _ in range(120):
            st = frame_stats()
            if st and st[2] > 3:
                break
            time.sleep(0.5)
        time.sleep(1.0)
        for f in boot_sequence():
            p.send(f)
        time.sleep(0.35)
        p.pump()
        p.send(sync_frame(True))
        time.sleep(0.4)
        p.pump()

        if mode == 'single':
            for _ in range(20):
                push_data(p, 0)
                time.sleep(0.12)
                p.pump()
            push_data(p, DATA['gear'])
            keep(p, 12)
        elif mode == 'dual':
            for _ in range(20):
                push_data(p, 0)
                time.sleep(0.12)
                p.pump()
            push_data(p, 0)
            time.sleep(0.9)
            p.pump()
            push_data(p, DATA['gear'])
            keep(p, 12)
        elif mode == 'quad':
            for _ in range(20):
                push_data(p, 0)
                time.sleep(0.12)
                p.pump()
            for _ in range(2):
                push_data(p, 0)
                time.sleep(0.9)
                p.pump()
                push_data(p, DATA['gear'])
                time.sleep(1.6)
                p.pump()
            keep(p, 10)

    st = frame_stats()
    p.close()
    from PIL import Image
    out = f'/tmp/entry_{mode}.png'
    Image.open('/tmp/ui-frame.ppm').convert('RGB').save(out)
    print(f"mode={mode}  nonblack={st[2]:.2f}%  teal={st[3]:.2f}%  -> {out}")


if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('--mode', required=True,
                    choices=['single', 'early', 'dual', 'quad'])
    run(ap.parse_args().mode)
