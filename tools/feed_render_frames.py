#!/usr/bin/env python3
"""MCU→仪表 上行帧喂食器（同时也是合规的 CFCP 对端）。

为什么需要 ACK（逆向结论，见 flutter_app/lib/emu/cfcp.dart:185-201）：
  guest 内核 CFCP 驱动收到一帧后，若帧要求 ACK 就回 ACK；反过来，guest 发出
  的 0x75 属性帧也要求对端（MCU）回 ACK。客户端若只发不回，guest 会
  `cfcp_ack_q_work_handl ... resend_times is 3` 重传 3 次后丢弃 →
  「应用层拿不到属性」→ 集群停在 LINE_DISCONNECT / 待机统计页。
  所以本脚本必须：① 收到 guest 数据帧就回静态 ACK；② 持续喂 KL15 + vehicle_info1。

帧格式（与真机抓包逐字节核对，cfcp.dart:243-321）：
  MAGIC fe5aaaa5 | FRAME0(0x11 属性 / 0x90 ACK) | FRAME1 | CMD(75 01 01 00) |
  LEN(u16 LE) | DATA | CHK(~sum[4..chk]&0xff) | TAIL a5555a
  属性 DATA = [inner u16][prop u32 LE][sub u32 LE][value]

用法：
  python3 Gemini-Dummy/tools/feed_render_frames.py            # 持续喂（默认 8s）
  python3 Gemini-Dummy/tools/feed_render_frames.py --duration 30
  python3 Gemini-Dummy/tools/feed_render_frames.py --kl15 0x55   # 关显示
  python3 Gemini-Dummy/tools/feed_render_frames.py --speed 250 --rpm 3000 --temp 80
"""
import argparse
import select
import socket
import struct
import sys
import time

MAGIC = b"\xfe\x5a\xaa\xa5"
TAIL = b"\xa5\x55\x5a"
CMD_PROP = 0x00010175

# 静态 ACK 帧（cfcp.dart:190）。对端收到任意非 ACK 帧都回这一帧。
ACK_FRAME = bytes(
    [0xFE, 0x5A, 0xAA, 0xA5, 0x90, 0x08, 0x55, 0x01, 0x01, 0x00, 0x00, 0x00, 0x10, 0xA5, 0x55, 0x5A]
)


def build(frame0, frame1, cmd, data):
    body = bytearray([frame0 & 0xFF, frame1 & 0xFF])
    body += cmd.to_bytes(4, "little")
    body += len(data).to_bytes(2, "little")
    body += bytes(data)
    return MAGIC + bytes(body) + bytes([(~sum(body)) & 0xFF]) + TAIL


def prop_frame(prop, sub, value):
    """value: bytes。inner = 4(prop)+4(sub)+len(value)；LEN = inner+2。"""
    inner = 4 + 4 + len(value)
    data = struct.pack("<HH", inner, prop & 0xFFFF)
    data += struct.pack("<H", (prop >> 16) & 0xFFFF)
    data += struct.pack("<I", sub & 0xFFFFFFFF)
    data += bytes(value)
    return build(0x11, 0x02, CMD_PROP, data)


def prop_int(prop, sub, v):
    # 无符号打包，避免 0xFFFFFFFF 这类满位掩码触发 signed 溢出（小值下字节一致）。
    return prop_frame(prop, sub, struct.pack("<I", v & 0xFFFFFFFF))


def prop_raw(prop, sub, v):
    return prop_frame(prop, sub, bytes(v))


def make_dataset(speed, rpm, temp, kl15):
    """基线 7 帧 + KL15 闸门 + vehicle_info1（20 字节向量）。"""
    frames = []
    frames.append(prop_frame(0x21701002, 0, b"SW.1.00.56 AE5I".ljust(24, b"\x00")))
    frames.append(prop_int(0x21417310, 0, 1))          # handshake
    frames.append(prop_int(0x27407404, 0, 0xFFFFFFFF))  # capability mask
    frames.append(prop_int(0x21707701, 0, 0xC0))        # vehicle status byte
    frames.append(prop_raw(0x21709702, 0, [8, 0]))     # gear (2B LE)
    frames.append(prop_int(0x21709521, 0, 0))           # heartbeat
    frames.append(prop_int(0x21407072, 0, 0))           # lamp mask (all off)
    frames.append(prop_int(0x21400030, 0, kl15))        # ★ KL15 整车就绪闸门
    vi1 = bytearray(20)
    struct.pack_into("<i", vi1, 0, speed)    # [0..3]  wheel_spd
    struct.pack_into("<i", vi1, 4, 0)        # [4..7]  inst_elec_consume
    # [8..11] 保留
    struct.pack_into("<i", vi1, 12, rpm)     # [12..15] engine_rpm
    struct.pack_into("<i", vi1, 16, temp)    # [16..19] water_temp
    frames.append(prop_raw(0x21707402, 0, vi1))
    return frames


def iter_frames(buf):
    """从字节流里切出所有完整 CFCP 帧，返回 (frames, leftover)。"""
    out = []
    off = 0
    while True:
        i = buf.find(MAGIC, off)
        if i < 0:
            break
        j = buf.find(TAIL, i)
        if j < 0:
            break
        out.append(buf[i:j + 3])
        off = j + 3
    return out, buf[off:]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=9123)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--kl15", type=lambda x: int(x, 0), default=0x99,
                    help="0x99=点亮/整车就绪, 0x55=待机熄屏")
    ap.add_argument("--speed", type=int, default=250)
    ap.add_argument("--rpm", type=int, default=3000)
    ap.add_argument("--temp", type=int, default=80)
    ap.add_argument("--interval", type=float, default=0.2, help="喂帧周期(s)")
    ap.add_argument("--duration", type=float, default=8.0, help="运行总时长(s)，0=常驻")
    ap.add_argument("--prime", type=float, default=0.0,
                    help="启动后用 KL15=0x55 预热多少秒（让 prev 状态进入 0x55/0x99 后再切 0x99）")
    args = ap.parse_args()

    try:
        s = socket.create_connection((args.host, args.port), timeout=5)
    except OSError as e:
        print(f"✗ 连不上 {args.host}:{args.port}（仿真器没起来？）：{e}", file=sys.stderr)
        sys.exit(1)
    s.setblocking(False)

    frames = make_dataset(args.speed, args.rpm, args.temp, args.kl15)

    def send_all():
        for f in frames:
            try:
                s.sendall(f)
            except OSError:
                return False
        return True

    print(f"→ 连接 {args.host}:{args.port}；每 {args.interval}s 喂 {len(frames)} 帧"
          f"（含 KL15={args.kl15:#x} / speed={args.speed} / rpm={args.rpm}）")
    print("→ 同时 ACK 所有来自 guest 的数据帧（建立 CFCP 链路）")

    acked = 0
    sent = 0
    last_feed = 0.0
    start = time.time()
    buf = b""

    # 预热：先用 KL15=0x55 把 prev 状态推到 0x55/0x99（绕过 handler 的 prev 守卫），再切 0x99
    if args.prime > 0:
        print(f"→ 预热 {args.prime}s：先发 KL15=0x55")
        prime_frames = make_dataset(args.speed, args.rpm, args.temp, 0x55)
        pend = time.time() + args.prime
        while time.time() < pend:
            for f in prime_frames:
                try:
                    s.sendall(f)
                except OSError:
                    break
            r, _, _ = select.select([s], [], [], args.interval)
            if r:
                try:
                    chunk = s.recv(16384)
                except (BlockingIOError, OSError):
                    chunk = b""
                if chunk:
                    buf += chunk
                    parsed, buf = iter_frames(buf)
                    for f in parsed:
                        if len(f) >= 16 and not (f[4] >> 7) & 1:
                            try:
                                s.sendall(ACK_FRAME)
                                acked += 1
                            except OSError:
                                pass
        print("→ 预热结束，切 KL15=0x99")

    next_ack_flusher = 0.0

    while True:
        if args.duration and (time.time() - start) >= args.duration:
            break
        # 喂帧（周期性）
        if time.time() - last_feed >= args.interval:
            if send_all():
                sent += len(frames)
            last_feed = time.time()
        # 收 guest 帧并 ACK
        r, _, _ = select.select([s], [], [], 0.05)
        if r:
            try:
                chunk = s.recv(16384)
            except (BlockingIOError, OSError):
                chunk = b""
            if not chunk:
                print("✗ 连接被 guest 关闭", file=sys.stderr)
                break
            buf += chunk
            parsed, buf = iter_frames(buf)
            for f in parsed:
                if len(f) < 16:
                    continue
                frame0 = f[4]
                is_response = (frame0 >> 7) & 1
                if not is_response:
                    # guest 数据帧 → 回 ACK
                    try:
                        s.sendall(ACK_FRAME)
                        acked += 1
                    except OSError:
                        pass
        # 周期性刷 ACK（guest 广播很频繁，这里不主动刷也行，但保底）
        now = time.time()
        if now - next_ack_flusher >= 0.5:
            next_ack_flusher = now

    s.close()
    print(f"done. 共喂 {sent} 帧，回 ACK {acked} 个。")


if __name__ == "__main__":
    main()
