"""PFC/DOV 背景层探针：回答三个问题

1. `PFC_DOV : get dov failed` 还有几次？
2. **window 1（0x0C600000，背景层）有没有被固件真的画上像素？**
3. 合成后的画面非黑占比 / 有没有整车拖尾。

用法：
    python3 tools/bg_probe.py            # 用当前 QEMU（默认 SP_IPC_MODE=2）
    python3 tools/bg_probe.py --mode 1   # 顺便用 mode 1 重启一次再测
"""
import argparse
import os
import socket
import subprocess
import sys
import time

LAB = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, LAB + '/tools')

from dash_up import (Peer, boot_sequence, sync_frame, vi2_frame, vi3_frame, batt_frame,
                     odo_frame, trip_frame, prop_u32, PROP_KL15, PROP_TRIP1, frame_stats)

FB0 = 0x0C000000
FB1 = 0x0C600000
FB2 = 0x0CC00000
PS = 1024 * 600 * 4


def pmemsave(addr, size, path):
    s = socket.socket(socket.AF_UNIX)
    s.connect('/tmp/ui-mon.sock')
    s.settimeout(10)
    time.sleep(0.2)
    try:
        s.recv(65536)
    except Exception:
        pass
    s.sendall(f'pmemsave {addr:#x} {size:#x} "{path}"\n'.encode())
    time.sleep(2.0)
    s.close()


def win_stats(addr, name):
    path = f'/tmp/bg_{name}.bin'
    pmemsave(addr, 0x500000, path)
    if not os.path.exists(path):
        print(f"  {name}: dump failed")
        return
    d = open(path, 'rb').read()
    for pg in (0, 1):
        p = d[pg * PS:(pg + 1) * PS]
        if len(p) < PS:
            continue
        nz = 0
        for i in range(0, PS, 4):
            if p[i] | p[i + 1] | p[i + 2] | p[i + 3]:
                nz += 1
        print(f"  {name} page{pg}: 非零像素 {nz} ({100.0*nz/(1024*600):.2f}%)")


def dov_failures():
    try:
        txt = open('/tmp/ui-serial.log', 'rb').read().decode('utf-8', 'replace')
    except OSError:
        return -1
    return txt.count('get dov failed')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--mode', type=int, default=None,
                    help='用这个 SP_IPC_MODE 重启 QEMU 再测（1=只回用户态）')
    ap.add_argument('--skip-enter', action='store_true')
    args = ap.parse_args()

    if args.mode is not None:
        subprocess.run(['pkill', '-9', '-f', 'qemu-system-arm'],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(1)
        env = dict(os.environ, SP_IPC_MODE=str(args.mode))
        subprocess.Popen(['bash', LAB + '/run_ui.sh'], env=env,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         start_new_session=True)
        for _ in range(60):
            s = socket.socket()
            s.settimeout(0.4)
            try:
                s.connect(('127.0.0.1', 9123))
                s.close()
                break
            except OSError:
                s.close()
                time.sleep(0.5)
        for _ in range(90):
            if os.path.exists('/tmp/ui-serial.log'):
                try:
                    if 'setViewUi end' in open('/tmp/ui-serial.log', 'rb').read().decode(
                            'utf-8', 'replace'):
                        break
                except OSError:
                    pass
            time.sleep(1)
        time.sleep(2)

    p = Peer('127.0.0.1', 9123)
    time.sleep(0.3)
    for f in boot_sequence():
        p.send(f)
    time.sleep(0.35)
    p.pump()
    p.send(sync_frame(True))
    time.sleep(0.4)
    p.pump()
    if not args.skip_enter:
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
        while time.time() - t0 < 10:
            p.pump()
            p.send(prop_u32(PROP_KL15, 0x99))
            p.send(sync_frame(True))
            p.send(vi3_frame(drive_mode=1, battery=91))
            p.send(batt_frame(91))
            p.send(odo_frame(5060, 287))
            p.send(trip_frame(PROP_TRIP1, 100, 35))
            time.sleep(0.2)
    st = frame_stats()
    print(f"frame: nonblack={st[2]:.2f}%  teal={st[3]:.2f}%")
    print(f"get dov failed: {dov_failures()}")
    print("window 统计（背景层应在这里有像素）：")
    win_stats(FB1, 'win1')
    win_stats(FB2, 'win2')
    p.close()
    from PIL import Image
    Image.open('/tmp/ui-frame.ppm').convert('RGB').save('/tmp/bg_probe.png')
    print("saved /tmp/bg_probe.png")


if __name__ == '__main__':
    main()
