#!/usr/bin/env python3
"""fb 链路诊断：通过 QEMU monitor 读取已确认地址的 guest framebuffer 状态。

SP_FB_TABLE_VA、SP_REGISTERED_FB_VA、SP_FB_USERS_VA 必须来自当前 kernel 的证据；
未提供时跳过地址探针。IPC stub 也必须通过 SP_IPC_STUB=1 显式启用。
"""
import os, re, socket, subprocess, sys, time

LAB = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = f"{LAB}/qemu-src/build/qemu-system-arm"
KERNEL = os.environ.get("SP_KERNEL", f"{LAB}/images/kernel-ae5i.bin")
SOCK = "/tmp/fbdiag.sock"
ANSI = re.compile(r'\x1b\[[0-9;]*[A-Za-z]')

try:
    os.unlink(SOCK)
except FileNotFoundError:
    pass

MTD = ("mtdparts=sp_spinand.0:0x40000(nand_header),0x40000(xboot1),0xc0000(uboot1),0x1c0000(uboot2),"
       "0x80000(env),0x80000(env_redund),0x400000(ecos),0x480000(kernel),0x480000(rootfs.),0x80000(opt.),"
       "0x3000000(spsdk.),0x4040000(spapp.),0x1000000(nvm),0x40000(pq),0x40000(tcon),0x40000(iop_car),"
       "0x100000(runtime_cfg),0x40000(vi),0x980000(isp_logo),0x40000(vendordata),0xbc0000(pat_logo),"
       "0x40000(version_info),0x40000(vd_restore),0x100000(anm_logo),0x15540000(userdata)")
APP = ("console=ttyS0,921600 loglevel=7 panic=1 " + MTD +
       " res_chunkmem=0x04000000@0x0C000000 res_fb0=0x00800000@0x0C000000"
       " res_fb1=0x00400000@0x0C800000 res_fb2=0x00400000@0x0CC00000")

env = dict(os.environ)
env["SP_VDISK"] = os.environ.get("SP_VDISK", f"{LAB}/images/ae5i.spvd")
if env.get("SP_IPC_STUB", "").lower() in ("", "0", "false", "off", "no"):
    env.pop("SP_IPC_STUB", None)
if os.environ.get("SP_MODE"):
    env["SP_IPC_MODE"] = os.environ["SP_MODE"]

proc = subprocess.Popen(
    [BIN, "-M", "sunplus-sp8368", "-m", "256", "-kernel", KERNEL, "-append", APP,
     "-serial", "file:/tmp/fbdiag.log", "-display", "none",
     "-monitor", f"unix:{SOCK},server,nowait", "-no-reboot"],
    env=env, stdout=subprocess.DEVNULL, stderr=open("/tmp/fbdiag.err", "wb"))

for _ in range(500):
    if os.path.exists(SOCK):
        break
    time.sleep(0.02)

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.connect(SOCK)
sock.settimeout(10)
time.sleep(0.5)


def cmd(c, w=1.0):
    sock.sendall((c + "\n").encode())
    time.sleep(w)
    out = b""
    try:
        while True:
            d = sock.recv(1 << 20)
            if not d:
                break
            out += d
            if len(out) > 1 << 21:
                break
    except socket.timeout:
        pass
    return ANSI.sub('', out.decode(errors="replace"))


def rd(addr, n=8):
    txt = cmd(f"xp /{n}xw {addr:x}", 1.2)
    vals = []
    for line in txt.splitlines():
        line = line.strip()
        if not re.match(r"^[0-9a-f]{6,}:", line):
            continue
        for tok in line.split(":", 1)[1].split():
            if re.fullmatch(r"0x[0-9a-f]{8}", tok):
                vals.append(int(tok, 16))
    return vals


def rds(addr, n=16):
    txt = cmd(f"xp/{n}cb {addr:x}", 1.2)
    for line in txt.splitlines():
        line = line.strip()
        if re.match(r"^0x[0-9a-f]{6,}:", line):
            return line
    return ""


# ARM Linux VA -> PA for this kernel mapping. Probe addresses are supplied per image.
def pa(va):
    return va - 0xC0000000


time.sleep(float(os.environ.get("SP_WAIT", "30")))

probe_vars = (
    ("vendor fb table", "SP_FB_TABLE_VA", 4),
    ("registered_fb[]", "SP_REGISTERED_FB_VA", 6),
    ("fb users", "SP_FB_USERS_VA", 2),
)
probe_values = {}
for label, var, words in probe_vars:
    value = os.environ.get(var)
    if value is None:
        print(f"== {label}: skipped ({var} not set) ==")
        continue
    va = int(value, 0)
    vals = rd(pa(va), words)
    probe_values[var] = vals
    print(f"== {label} @VA {va:#x} ==\n  { [hex(x) for x in vals] }")

vt = probe_values.get("SP_FB_TABLE_VA", [])
if vt and vt[0] and os.environ.get("SP_FB_INFO_OFFSETS_CONFIRMED") == "1":
    fb = vt[0]
    p = pa(fb)
    print(f"== fb_info VA={hex(fb)} ==")
    for name, off in (("index", 0x0), ("+0x1a4", 0x1a4), ("+0x220", 0x220),
                      ("+0x228 dev", 0x228), ("+0x244", 0x244), ("+0x248", 0x248)):
        v = rd(p + off, 1)
        print(f"   {name:10s}= {hex(v[0]) if v else '?'}")
    print("   id str :", rds(p + 0xc4, 24))
    print("   +0x1a0 :", [hex(x) for x in rd(p + 0x1a0, 6)])
    print("   +0x230 :", [hex(x) for x in rd(p + 0x230, 6)])
elif vt and vt[0]:
    print("fb_info field probe skipped (set SP_FB_INFO_OFFSETS_CONFIRMED=1 only for a verified layout)")

cmd("quit")
try:
    proc.wait(timeout=10)
except Exception:
    proc.kill()
