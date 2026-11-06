#!/usr/bin/env python3
"""从 guest 拉取一段文件到宿主，分块 + 每块 md5 校验 + 失败重传。

背景：guest 控制台（ttyS0, 921600）会被 Launcher/AudioService 等用户态日志
交错插入，直接 `base64 file` 一次传完会丢字符且无法定位。本工具把范围切成
小块，每块：guest 侧 dd 出小文件 → md5 + 长度 → base64 打印；宿主按 md5
校验，不一致就重传该块，直到成功或超限。

用法:
  guest_pull.py <guest_path> <host_out> <offset> <size> [chunk]

环境:
  SP_SH_PORT   串口 socket 端口（默认 4510）
  SP_VDISK     SPVD 镜像（默认 images/ae5i.spvd）
  SP_START_WAIT 等待 userland 上限秒（默认 260）
  SP_CMD_TIMEOUT 单块超时秒（默认 40）
"""
import base64
import hashlib
import os
import re
import socket
import subprocess
import sys
import threading
import time

LAB = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = f"{LAB}/qemu-src/build/qemu-system-arm"
KERNEL = os.environ.get("SP_KERNEL", f"{LAB}/images/kernel-ae5i.bin")
PORT = int(os.environ.get("SP_SH_PORT", "4510"))
MTDPARTS = ("mtdparts=sp_spinand.0:0x40000(nand_header),0x40000(xboot1),"
            "0xc0000(uboot1),0x1c0000(uboot2),0x80000(env),0x80000(env_redund),"
            "0x400000(ecos),0x480000(kernel),0x480000(rootfs.),0x80000(opt.),"
            "0x3000000(spsdk.),0x4040000(spapp.),0x1000000(nvm),0x40000(pq),"
            "0x40000(tcon),0x40000(iop_car),0x100000(runtime_cfg),0x40000(vi),"
            "0x980000(isp_logo),0x40000(vendordata),0xbc0000(pat_logo),"
            "0x40000(version_info),0x40000(vd_restore),0x100000(anm_logo),"
            "0x15540000(userdata)")
APPEND = " ".join(["console=ttyS0,921600", "loglevel=7", "panic=1", MTDPARTS,
                   "res_chunkmem=0x04000000@0x0C000000",
                   "res_fb0=0x00600000@0x0C000000",
                   "res_fb1=0x00600000@0x0C600000",
                   "res_fb2=0x00600000@0x0CC00000"])
env = dict(os.environ)
env["SP_VDISK"] = os.environ.get("SP_VDISK", f"{LAB}/images/ae5i.spvd")
profile = os.environ.get("SP_COMPLETE_BOOT", "1").lower()
ipc_requested = os.environ.get("SP_IPC_STUB")
if ipc_requested is None and profile not in ("", "0", "false", "off", "no"):
    ipc_requested = "1"
ipc_stub = (ipc_requested or "").lower()
if ipc_stub not in ("", "0", "false", "off", "no"):
    env["SP_IPC_STUB"] = ipc_requested
else:
    env.pop("SP_IPC_STUB", None)

err = open("/tmp/pull.err", "wb")
serial_args = ["-chardev", f"socket,host=127.0.0.1,port={PORT},server=on,wait=off,id=c0",
               "-serial", "chardev:c0"]
p = subprocess.Popen(
    [BIN, "-M", "sunplus-sp8368", "-m", "256", "-kernel", KERNEL, "-append", APPEND,
     *serial_args, "-display", "none", "-monitor", "none", "-no-reboot"],
    env=env, stdout=subprocess.DEVNULL, stderr=err)

buf = bytearray()
lock = threading.Lock()
stop = [False]
sock = [None]


def reader():
    s = None
    t0 = time.time()
    while time.time() - t0 < 40 and s is None:
        try:
            s = socket.create_connection(("127.0.0.1", PORT), 2)
        except OSError:
            time.sleep(0.2)
    if s is None:
        print("connect failed", file=sys.stderr)
        return
    sock[0] = s
    s.settimeout(0.3)
    while not stop[0]:
        try:
            d = s.recv(65536)
        except socket.timeout:
            continue
        except OSError:
            break
        if not d:
            break
        with lock:
            buf.extend(d)


threading.Thread(target=reader, daemon=True).start()


def send(line):
    if sock[0] is None:
        return
    try:
        sock[0].sendall(line.encode() + b"\n")
    except OSError as e:
        print("send failed", e, file=sys.stderr)


def snap():
    with lock:
        return bytes(buf)


def wait_re(pat, start, timeout):
    """等待 pat 出现；pat 必须锚定行首，避免命中命令回显里的标记。"""
    rx = re.compile(pat.encode())
    end = time.time() + timeout
    while time.time() < end:
        m = rx.search(snap(), start)
        if m:
            return m
        time.sleep(0.02)
    return None


MARK = b"Freeing unused kernel memory"
t0 = time.time()
while time.time() - t0 < float(os.environ.get("SP_START_WAIT", "260")):
    if p.poll() is not None:
        print(f"QEMU exited early rc={p.returncode}", file=sys.stderr)
        sys.exit(1)
    if MARK in snap():
        break
    time.sleep(1)
else:
    print("never reached userland", file=sys.stderr)
    p.terminate()
    sys.exit(1)

t0 = time.time()
while time.time() - t0 < 120:
    if re.search(rb"root@[A-Za-z0-9_.-]+:/#", snap()):
        break
    time.sleep(1)
print("guest shell ready", file=sys.stderr)


def run(cmd, timeout=30):
    tok = f"Q{int(time.time() * 1000000) % 100000000}"
    start = len(snap())
    send(f"{cmd}; echo {tok}")
    m = wait_re(rf"(?:^|\r?\n){tok}\r?\n", start, timeout)
    if not m:
        return None
    return snap()[start:m.start()].decode("utf-8", "replace")


# 降低内核日志 + 停掉刷屏用户态日志进程（失败也无妨）
run("echo 1 > /proc/sys/kernel/printk")
run("killall -9 Launcher AudioService network_server 2>/dev/null")
time.sleep(0.5)


def pull_chunk(path, off, n, chunk_timeout):
    """返回该块原始字节；失败返回 None。"""
    for attempt in range(12):
        tok = f"P{int(time.time() * 1000000) % 100000000}"
        start = len(snap())
        send(f"dd if={path} bs=1 skip={off} count={n} 2>/dev/null > /tmp/_c.bin; "
             f"base64 /tmp/_c.bin > /tmp/_c.b64; "
             f"echo M{tok} $(md5sum /tmp/_c.bin | cut -d' ' -f1) $(wc -c < /tmp/_c.bin)")
        m = wait_re(rf"(?:^|\r?\n)M{tok} ([0-9a-f]{{32}}) (\d+)", start, chunk_timeout)
        if not m:
            continue
        want_md5 = m.group(1).decode()
        want_len = int(m.group(2))

        start2 = len(snap())
        send(f"echo S{tok}; cat /tmp/_c.b64; echo E{tok}")
        ms = wait_re(rf"(?:^|\r?\n)S{tok}\r?\n", start2, chunk_timeout)
        if not ms:
            continue
        me = wait_re(rf"(?:^|\r?\n)E{tok}\r?\n", ms.end(), chunk_timeout)
        if not me:
            continue
        body = snap()[ms.end():me.start()].decode("utf-8", "replace")
        b64 = re.sub(r"[^A-Za-z0-9+/=]", "", body)
        try:
            raw = base64.b64decode(b64, validate=True)
        except Exception:
            continue
        if len(raw) != want_len:
            continue
        if hashlib.md5(raw).hexdigest() != want_md5:
            continue
        return raw
    return None


def main():
    if len(sys.argv) < 5:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    gpath = sys.argv[1]
    hout = sys.argv[2]
    off = int(sys.argv[3], 0)
    size = int(sys.argv[4], 0)
    chunk = int(sys.argv[5], 0) if len(sys.argv) > 5 else 4096
    chunk_timeout = float(os.environ.get("SP_CMD_TIMEOUT", "40"))

    out = bytearray()
    pos = 0
    t_start = time.time()
    while pos < size:
        n = min(chunk, size - pos)
        raw = pull_chunk(gpath, off + pos, n, chunk_timeout)
        if raw is None:
            # 缩小块重试（噪声大时更容易成功）
            if chunk > 256:
                chunk //= 2
                print(f"chunk shrink -> {chunk}", file=sys.stderr)
                continue
            print(f"FAILED at offset {off + pos}", file=sys.stderr)
            sys.exit(1)
        out.extend(raw)
        pos += len(raw)
        if pos % (chunk * 20) < chunk or pos == size:
            print(f"  {pos}/{size} ({100.0 * pos / size:.1f}%) "
                  f"{time.time() - t_start:.0f}s", file=sys.stderr)
    with open(hout, "wb") as f:
        f.write(out)
    print(f"OK {len(out)} bytes -> {hout} md5={hashlib.md5(bytes(out)).hexdigest()}",
          file=sys.stderr)


try:
    main()
finally:
    stop[0] = True
    p.terminate()
