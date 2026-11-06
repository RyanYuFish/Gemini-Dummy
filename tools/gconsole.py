#!/usr/bin/env python3
"""Talk to the guest firmware's own root console (ttyS0) over a unix socket.

run_ui.sh attaches the guest console to /tmp/ui-console.sock (and still logs to
/tmp/ui-serial.log), so we can inspect the running firmware from the inside
instead of guessing from the outside:

    # what props does the firmware have?
    python3 tools/gconsole.py 'getprop | grep -i pswd'

    # what does its settings ini look like?
    python3 tools/gconsole.py 'cat /media/flash/nvm/Sunplus/PluginsInfo.ini'

Output is filtered: kernel prints ("[  123.456] ...") and app log lines
("01-01 00:00:12.345 ...") are dropped so the command result stays readable.
"""
import argparse
import os
import re
import socket
import sys
import time

SOCK = '/tmp/ui-console.sock'
BEGIN = '<<<B>>>'
END = '<<<E>>>'

KLOG = re.compile(r'^\[\s*\d+\.\d+\]\s')
ALOG = re.compile(r'^\d\d-\d\d \d\d:\d\d:\d\d\.\d+\s')


def connect(timeout=5.0):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    s.connect(SOCK)
    return s


def read_until(s, marker, deadline):
    buf = b''
    while time.time() < deadline:
        try:
            chunk = s.recv(65536)
        except socket.timeout:
            continue
        except OSError:
            break
        if chunk:
            buf += chunk
            if marker in buf:
                break
    return buf


def wait_prompt(s, seconds):
    deadline = time.time() + seconds
    buf = b''
    while time.time() < deadline:
        try:
            s.sendall(b'\n')
        except OSError:
            break
        try:
            buf += s.recv(65536)
        except socket.timeout:
            pass
        if b'root@' in buf[-400:]:
            return True
    return b'root@' in buf[-400:]


def run(s, cmd, timeout=60.0):
    """Run cmd in the guest and return its stdout/stderr.

    The console echoes what we type, so a marker string appears at least twice
    in the stream before the real output starts; we wait for the third
    occurrence (the trailing one) and keep what sits between the last two.
    """
    mark = 'ZQ7END'
    script = '\n%s > /tmp/gc.out 2>&1\necho %s\ncat /tmp/gc.out\necho %s\n' % (
        cmd, mark, mark)
    s.sendall(script.encode())
    buf = b''
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            chunk = s.recv(65536)
        except socket.timeout:
            continue
        except OSError:
            break
        if not chunk:
            continue
        buf += chunk
        if buf.count(mark.encode()) >= 3:
            break
    text = buf.decode('utf-8', 'replace').replace('\r', '')
    parts = text.split(mark)
    body = parts[-2] if len(parts) >= 2 else ''
    out = []
    for line in body.split('\n'):
        if KLOG.match(line) or ALOG.match(line):
            continue
        out.append(line)
    return '\n'.join(out).strip('\n')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('cmd', nargs='+', help='shell command(s) to run in the guest')
    ap.add_argument('--wait', type=float, default=0,
                    help='seconds to wait for the root prompt before the first command')
    ap.add_argument('--timeout', type=float, default=90.0)
    a = ap.parse_args()

    if not os.path.exists(SOCK):
        sys.exit(f'{SOCK} 不存在：先 bash run_ui.sh（它会把 guest 控制台挂到这个 socket）')

    s = connect()
    try:
        if a.wait and not wait_prompt(s, a.wait):
            print('（没等到 root 提示符，仍然尝试执行）', file=sys.stderr)
        for cmd in a.cmd:
            print(f'$ {cmd}')
            print(run(s, cmd, a.timeout))
            print()
    finally:
        s.close()


if __name__ == '__main__':
    main()
