#!/usr/bin/env python3
"""Pull a file out of the running guest over its root console (base64 + md5).

The emulator exposes the guest console on /tmp/ui-console.sock (see
run_ui.sh).  There is no network between guest and host, so this is how we get
the firmware's own AE5I libraries onto the host for real disassembly instead of
reasoning from the AE4i extraction in virtual/spapp-root.

    python3 tools/gpull.py /application/lib/module/libdashclustormodule.so \
        /tmp/ae5i_spapp/lib/module/libdashclustormodule.so

Verifies md5 on both sides; exits non-zero on mismatch.
"""
import argparse
import base64
import hashlib
import os
import re
import socket
import sys
import time

SOCK = '/tmp/ui-console.sock'
B64LINE = re.compile(r'^[A-Za-z0-9+/=]{16,}$')


def connect(timeout=5.0):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    s.connect(SOCK)
    return s


def guest_md5(s, path):
    mark = 'MD5X'
    s.sendall(('\nmd5sum %s > /tmp/gp.chk 2>&1\necho %s\ncat /tmp/gp.chk\n'
               % (path, mark)).encode())
    buf = b''
    deadline = time.time() + 60
    while time.time() < deadline:
        try:
            chunk = s.recv(65536)
        except socket.timeout:
            continue
        if not chunk:
            continue
        buf += chunk
        if buf.count(mark.encode()) >= 2 and b'/tmp/gp.chk' in buf:
            time.sleep(0.3)
            try:
                buf += s.recv(65536)
            except (socket.timeout, OSError):
                pass
            break
    text = buf.decode('utf-8', 'replace')
    for line in text.split('\n'):
        line = line.strip()
        m = re.match(r'^([0-9a-f]{32})\s', line)
        if m:
            return m.group(1)
    return None


def _mark_lines(buf, mark):
    """Count how many *whole lines* equal mark (an echoed command is not one)."""
    return sum(1 for ln in buf.decode('utf-8', 'replace').split('\n')
               if ln.strip() == mark)


def exec_capture(s, script, mark, timeout):
    """Run one guest command and return the text printed between two marks.

    The console echoes the typed line, so the marks are emitted by `echo` on
    their own line and we key on whole-line equality (the echo of the command
    keeps the mark inside a longer line).
    """
    begin = mark + 'B'
    end = mark + 'E'
    s.sendall(('\necho %s\n%s\necho %s\n' % (begin, script, end)).encode())
    buf = b''
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            chunk = s.recv(65536)
        except socket.timeout:
            continue
        if not chunk:
            continue
        buf += chunk
        if _mark_lines(buf, end) >= 1:
            break
    lines = buf.decode('utf-8', 'replace').split('\n')
    starts = [i for i, ln in enumerate(lines) if ln.strip() == begin]
    ends = [i for i, ln in enumerate(lines) if ln.strip() == end]
    if not starts or not ends:
        return ''
    a = starts[0] + 1
    b = ends[-1]
    return '\n'.join(lines[a:b]) if b > a else ''


def pull(s, path, dest):
    """base64 the file in the guest, then stream it back and decode."""
    out = exec_capture(s, 'wc -c < %s' % path, 'SZQ', 40)
    size = None
    for line in out.split('\n'):
        line = line.strip()
        if line.isdigit():
            size = int(line)
            break
    if size is None:
        raise RuntimeError(f'拿不到文件大小: {out!r}')

    tmp = '/tmp/gp.b64'
    print(f'   在 guest 中编码 {size} B ...', flush=True)
    exec_capture(s, 'base64 %s > %s' % (path, tmp), 'B64Q',
                 60 + size / 20000.0)

    total = (size + 2) // 3 * 4
    print(f'   base64 {total} B，开始回传', flush=True)

    s.sendall(('\ncat %s\necho B64END\n' % tmp).encode())
    data = bytearray()
    pending = b''
    deadline = time.time() + 120 + total / 30000.0
    last = time.time()
    lastpct = -1
    done = False
    while time.time() < deadline and not done:
        try:
            chunk = s.recv(262144)
        except socket.timeout:
            chunk = b''
        if chunk:
            pending += chunk
            last = time.time()
            lines = pending.split(b'\n')
            pending = lines.pop()
            for ln in lines:
                s_ = ln.strip()
                if s_ == b'B64END':
                    done = True
                    break
                if len(s_) >= 16 and B64LINE.match(s_.decode('ascii', 'ignore')):
                    data += s_
            pct = len(data) * 100 // total if total else 0
            if pct >= lastpct + 20:
                lastpct = pct
                print(f'   {pct}%  {len(data)}/{total}', flush=True)
        else:
            if time.time() - last > 20:
                break
    if pending.strip():
        ln = pending.strip()
        if B64LINE.match(ln.decode('ascii', 'ignore')):
            data += ln

    raw = base64.b64decode(bytes(data), validate=False)[:size]
    os.makedirs(os.path.dirname(dest) or '.', exist_ok=True)
    with open(dest, 'wb') as f:
        f.write(raw)
    return raw


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('guest_path')
    ap.add_argument('host_path')
    ap.add_argument('--skip-md5', action='store_true')
    a = ap.parse_args()

    if not os.path.exists(SOCK):
        sys.exit(f'{SOCK} 不存在：先 bash run_ui.sh')

    s = connect()
    try:
        want = None if a.skip_md5 else guest_md5(s, a.guest_path)
        print(f'  guest md5: {want}', flush=True)
        t0 = time.time()
        raw = pull(s, a.guest_path, a.host_path)
        got = hashlib.md5(raw).hexdigest()
        print(f'  写入 {a.host_path}  {len(raw)} B  {time.time()-t0:.1f}s  host md5: {got}')
        if want and want != got:
            sys.exit('md5 不匹配：传输有丢字节，重试或降速')
        print('  OK')
    finally:
        s.close()


if __name__ == '__main__':
    main()
