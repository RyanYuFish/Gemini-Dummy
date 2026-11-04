#!/usr/bin/env python3
"""ZEEHO AE5I instrument emulator - host side.

NOTE (2026-11-01): 本文件属于**历史路线 A**（Debian 内核 + `-M virt` + `virtual/*.squashfs`），
**已不作为验证路线**。当前验证镜像 = `images/ae5i.spvd` + `images/kernel-ae5i.bin`
（源 dump `firmware/nand-backup/AE5 .BIN`，AE5I），入口 `tools/guest_shell.py` / `tools/fb_diag.py`；
详见 `docs/EMULATION.md` §15。

Owns one QEMU instance and exposes it over a small HTTP API so the web UI can show
the instrument screen, the serial console and inject key presses.

  python3 emu.py            # start QEMU + serve UI on http://127.0.0.1:8800
  python3 emu.py --no-run   # serve only (attach to an already running QEMU)

Standard library only. Nothing here flashes or touches vehicle hardware.
"""
import argparse, http.server, json, os, socket, socketserver, struct, subprocess, sys, threading, time, zlib

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
VIRTUAL = os.path.join(ROOT, 'virtual')

QEMU = '/opt/homebrew/bin/qemu-system-arm'
KERNEL = os.path.join(HERE, 'kernel/vmlinuz-armhf')
INITRD = os.path.join(HERE, 'initrd-final.cpio.gz')
SPDK = os.path.join(VIRTUAL, 'spsdk.squashfs')
SPAPP = os.path.join(VIRTUAL, 'spapp.squashfs')

MON_PORT = 4445
VNC_PORT = 5901
HTTP_PORT = 8800
SERIAL_LOG = '/tmp/ae5i-serial.log'
FRAME_PPM = '/tmp/ae5i-frame.ppm'

# Physical instrument keys, mapped to QEMU monitor `sendkey` names.
# Real keys arrive from the GD32 MCU over CFCP (/dev/ttyS1); until that channel is
# emulated these are plain keystrokes, so the mapping is a placeholder.
INSTRUMENT_KEYS = [
    ('SET', 'ret'), ('MODE', 'm'), ('UP', 'up'), ('DOWN', 'down'),
    ('LEFT', 'left'), ('RIGHT', 'right'), ('READY', 'r'), ('P', 'p'),
]


def qemu_cmdline():
    return [QEMU, '-M', 'virt,highmem=off', '-cpu', 'cortex-a7', '-m', '768',
            '-kernel', KERNEL, '-initrd', INITRD,
            '-device', 'virtio-gpu-pci,xres=1024,yres=600',
            '-device', 'virtio-keyboard-pci',
            '-drive', 'file=%s,if=none,format=raw,id=sdk' % SPDK,
            '-device', 'virtio-blk-device,drive=sdk',
            '-drive', 'file=%s,if=none,format=raw,id=app' % SPAPP,
            '-device', 'virtio-blk-device,drive=app',
            '-display', 'vnc=127.0.0.1:%d' % (VNC_PORT - 5900),
            '-monitor', 'telnet:127.0.0.1:%d,server,nowait' % MON_PORT,
            '-serial', 'file:%s' % SERIAL_LOG,
            '-append', 'console=ttyAMA0 rdinit=/sbin/qpreinit.sh',
            '-no-reboot']


def monitor(cmd, wait=1.2):
    """Send one command to the QEMU monitor. A new connection per command: the
    telnet monitor only holds one client and drops the previous one."""
    try:
        s = socket.create_connection(('127.0.0.1', MON_PORT), timeout=5)
        time.sleep(0.25)
        s.recv(65536)
        s.sendall((cmd + '\n').encode())
        time.sleep(wait)
        out = b''
        s.settimeout(0.6)
        try:
            while True:
                b = s.recv(65536)
                if not b:
                    break
                out += b
        except socket.timeout:
            pass
        s.close()
        return out.decode('utf-8', 'replace')
    except OSError as e:
        return 'monitor error: %s' % e


def ppm_to_png(path):
    try:
        d = open(path, 'rb').read()
    except OSError:
        return None
    parts = d.split(b'\n', 3)
    if len(parts) < 4 or parts[0].strip() != b'P6':
        return None
    w, h = int(parts[1].split()[0]), int(parts[1].split()[1])
    data = parts[3]
    raw = bytearray()
    for y in range(h):
        raw.append(0)
        raw += data[y * w * 3:(y + 1) * w * 3]

    def chunk(k, dd):
        return struct.pack('>I', len(dd)) + k + dd + struct.pack('>I', zlib.crc32(k + dd) & 0xffffffff)

    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(bytes(raw), 6)) + chunk(b'IEND', b''))


class Emulator:
    def __init__(self):
        self.proc = None
        self.lock = threading.Lock()

    def running(self):
        return self.proc is not None and self.proc.poll() is None

    def start(self):
        with self.lock:
            if self.running():
                return False
            for p in (SERIAL_LOG, FRAME_PPM):
                try:
                    os.remove(p)
                except OSError:
                    pass
            open(SERIAL_LOG, 'w').close()
            self.proc = subprocess.Popen(qemu_cmdline(), stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)
            return True

    def stop(self):
        with self.lock:
            if self.proc and self.proc.poll() is None:
                self.proc.terminate()
                try:
                    self.proc.wait(timeout=8)
                except subprocess.TimeoutExpired:
                    self.proc.kill()
            self.proc = None

    def frame(self):
        monitor('screendump %s' % FRAME_PPM, wait=1.6)
        return ppm_to_png(FRAME_PPM)

    def log(self, offset):
        try:
            txt = open(SERIAL_LOG, 'rb').read()
        except OSError:
            return '', 0
        # keep the tail bounded so the UI stays responsive
        if len(txt) > 400000:
            txt = txt[-400000:]
        return txt.decode('utf-8', 'replace'), len(txt)

    def key(self, name):
        return monitor('sendkey %s' % name, wait=0.5)


EMU = Emulator()
UI = os.path.join(HERE, 'ui', 'index.html')


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, body, ctype):
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split('?')[0]
        if path in ('/', '/index.html'):
            try:
                return self._send(200, open(UI, 'rb').read(), 'text/html; charset=utf-8')
            except OSError:
                return self._send(500, b'missing ui/index.html', 'text/plain')
        if path == '/api/frame.png':
            png = EMU.frame()
            if png is None:
                return self._send(503, b'no frame yet', 'text/plain')
            return self._send(200, png, 'image/png')
        if path == '/api/log':
            text, size = EMU.log(0)
            return self._send(200, json.dumps({'size': size, 'text': text}).encode(), 'application/json')
        if path == '/api/status':
            return self._send(200, json.dumps({'running': EMU.running()}).encode(), 'application/json')
        self._send(404, b'not found', 'text/plain')

    def do_POST(self):
        path = self.path.split('?')[0]
        n = int(self.headers.get('Content-Length') or 0)
        body = self.rfile.read(n).decode() if n else ''
        if path == '/api/start':
            return self._send(200, json.dumps({'started': EMU.start()}).encode(), 'application/json')
        if path == '/api/stop':
            EMU.stop()
            return self._send(200, json.dumps({'stopped': True}).encode(), 'application/json')
        if path == '/api/key':
            try:
                name = json.loads(body).get('key', '')
            except ValueError:
                name = ''
            if not name or not all(c.isalnum() or c in '-_' for c in name):
                return self._send(400, b'bad key', 'text/plain')
            return self._send(200, json.dumps({'out': EMU.key(name)}).encode(), 'application/json')
        self._send(404, b'not found', 'text/plain')


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--no-run', action='store_true', help='do not launch QEMU')
    ap.add_argument('--port', type=int, default=HTTP_PORT)
    args = ap.parse_args()
    if not args.no_run:
        EMU.start()
        print('QEMU started (monitor tcp/%d, vnc tcp/%d)' % (MON_PORT, VNC_PORT))
    print('UI: http://127.0.0.1:%d' % args.port)
    try:
        Server(('127.0.0.1', args.port), Handler).serve_forever()
    except KeyboardInterrupt:
        EMU.stop()


if __name__ == '__main__':
    main()
