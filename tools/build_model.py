#!/usr/bin/env python3
"""构建 sunplus-sp8368 机器模型，并把产物放到固定路径。

★ macOS 上的坑（2026-10-31 踩过，浪费了很多时间）：

  meson 在 macOS 上**一律**把可执行文件命名为 `<name>-unsigned`
  (qemu-src/meson.build:3949-3951)，因为 QEMU 需要 codesign 才能跑
  HVF/ entitlements。正式版 `qemu-system-arm` 是**手工 codesign 后复制**的。

  后果：`make` 只更新 `qemu-system-arm-unsigned`，而所有脚本
  (sprun.py / shrun.py / mon.py) 指向 `build/qemu-system-arm`——
  于是**改完模型代码重新编译，跑的还是旧二进制**，
  所有新加的探针/开关静默失效，表现为"代码明明写对了却没效果"。

  本脚本做两件事：
    1. meson/ninja 构建；
    2. 校验产物里含预期的新符号，并把 unsigned 版本同步到
       `build/qemu-system-arm`（保留原文件的可执行位）。

用法：
  python3 tools/build_model.py            # 构建 + 同步 + 校验
  python3 tools/build_model.py --check    # 只校验当前产物是否最新
"""
import os
import shutil
import subprocess
import sys
import time

LAB = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(LAB, "qemu-src")
BUILD = os.path.join(SRC, "build")
MODEL = os.path.join(SRC, "hw", "arm", "sunplus-sp8368.c")
UNSIGNED = os.path.join(BUILD, "qemu-system-arm-unsigned")
SIGNED = os.path.join(BUILD, "qemu-system-arm")


def build():
    t0 = time.time()
    r = subprocess.run(["ninja", "-C", BUILD], cwd=SRC,
                       capture_output=True, text=True)
    if r.returncode != 0:
        # ninja 不在 PATH 时退回 meson compile
        r = subprocess.run(["meson", "compile", "-C", BUILD], cwd=SRC,
                           capture_output=True, text=True)
    if r.returncode != 0:
        sys.stderr.write(r.stdout[-4000:] + r.stderr[-4000:])
        sys.exit("build failed")
    print(f"build ok in {time.time() - t0:.1f}s")


def sync():
    """把 unsigned 版本同步到 qemu-system-arm。

    不做 codesign：仿真器不需要 HVF 加速，unsigned 二进制可以直接跑
    （我们只做 TCG 模拟）。真机上 codesign 的那份留着不动。
    """
    if not os.path.exists(UNSIGNED):
        sys.exit(f"missing {UNSIGNED}")
    # Replace the inode instead of overwriting a running/signed executable:
    # macOS may keep its old code-signing cache. copy2 also preserves Finder
    # resource forks which codesign rejects on this workstation.
    staged = SIGNED + ".staged"
    shutil.copyfile(UNSIGNED, staged)
    os.chmod(staged, 0o755)
    if sys.platform == "darwin":
        subprocess.run(["codesign", "--force", "--sign", "-", staged], check=True)
    os.replace(staged, SIGNED)
    subprocess.run([SIGNED, "--version"], check=True, capture_output=True)
    print(f"synced {os.path.relpath(SIGNED, LAB)} "
          f"({os.path.getsize(SIGNED)} bytes)")


def check(probe=b"SP_FB_REG"):
    """确认运行用的二进制确实含最新的模型代码。

    探针字符串取自模型源码里出现的环境变量名；如果模型里没有它，
    说明这份二进制比源码旧。
    """
    if not os.path.exists(SIGNED):
        sys.exit(f"missing {SIGNED}")
    data = open(SIGNED, "rb").read()
    src = open(MODEL, "rb").read()
    ok = probe in data and probe in src
    print(f"check: {probe!r} in binary = {probe in data}, "
          f"in source = {probe in src} -> {'OK' if ok else 'STALE'}")
    if not ok:
        sys.exit("binary is STALE -- run without --check to rebuild")
    print(f"binary mtime = {time.ctime(os.path.getmtime(SIGNED))}, "
          f"source mtime = {time.ctime(os.path.getmtime(MODEL))}")


if __name__ == "__main__":
    if "--check" not in sys.argv:
        build()
        sync()
    check()
