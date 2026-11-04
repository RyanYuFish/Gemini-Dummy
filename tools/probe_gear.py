#!/usr/bin/env python3
"""Probe: with the CFCP link ACKed, step the GEAR property and watch for a
PGEAR scene switch (serial log).  Reuses feed_render_frames' frame builders."""
import sys, os, socket, time, threading, subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import feed_render_frames as F

ACK = bytes.fromhex('fe5aaaa5900855010100000010a5555a')
SERIAL = '/tmp/ui-serial.log'


def log_scene_lines():
    try:
        out = subprocess.run(['grep', '-inE',
                              'showViewGear|hideViewGear|PGEAR|Sence|updateViewGear|slot_delayUpdateGear',
                              SERIAL], capture_output=True, text=True).stdout
        return out
    except Exception:
        return ''


def main():
    gears = [int(x, 0) for x in (sys.argv[1:] or ['1', '2', '3', '4', '8', '0'])]
    s = socket.create_connection(('127.0.0.1', 9123), timeout=5)
    s.setblocking(False)
    stop = False
    buf = b''

    def ack_loop():
        nonlocal buf
        while not stop:
            try:
                c = s.recv(8192)
            except BlockingIOError:
                time.sleep(0.003)
                continue
            except OSError:
                break
            if not c:
                break
            buf += c
            while True:
                i = buf.find(b'\xfe\x5a\xaa\xa5')
                if i < 0:
                    break
                j = buf.find(b'\xa5\x55\x5a', i)
                if j < 0:
                    break
                buf = buf[j + 3:]
                try:
                    s.sendall(ACK)
                except OSError:
                    return

    threading.Thread(target=ack_loop, daemon=True).start()

    base = F.make_dataset(0, 0, 25, 0x99)   # light up
    for fr in base:
        s.sendall(fr)
    time.sleep(3)

    before = log_scene_lines()
    for g in gears:
        gf = F.prop_raw(0x21709702, 0, [g & 0xff, (g >> 8) & 0xff])
        for _ in range(6):
            s.sendall(gf)
            s.sendall(F.prop_int(0x21400030, 0, 0x99))
            s.sendall(F.prop_int(0x21709521, 0, 0))
            time.sleep(0.25)
        after = log_scene_lines()
        newlines = [l for l in after.splitlines() if l not in before.splitlines()]
        print(f"gear={g}: new scene log lines = {len(newlines)}")
        for l in newlines[-4:]:
            print("   ", l)
        before = after

    stop = True
    time.sleep(0.2)
    print("done")


if __name__ == '__main__':
    main()
