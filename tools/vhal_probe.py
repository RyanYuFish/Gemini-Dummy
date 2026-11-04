#!/usr/bin/env python3
"""CFCP 上行载荷（vhal frame array）探针 + 回包监听。

背景
----
仪表 SoC 侧只有 CFCP（/dev/ttyS1 @115200）。上行 ride-info 的接收点是
`mcucom_rx_ride_info_update(u8,u8,u8,u8*,u16) @0x397c4`。外层 DATA 必须是
**vhal frame array**，裸 TLV 会被内核打回。

已解出的结论（本工具实测）
--------------------------
报错行会回显内核自己解析出的字段：

    [CFCP] cfcp_parse_prop_data.L279 exist illegel vhal frame array,
           vhal_frame_len : 64 index = 0 vhal_len : 465.

用「单字节置 0xFF」逐位探测反解出：`vhal_len` = **元素偏移 0 处的 LE u16 + 2**，
且解析器按该值步进。即元素布局为

    struct elem { u16 payload_len;  /* LE，不含本头 */  u8 payload[payload_len]; };

全零 DATA 等价于连续的空元素，因此**不报错**。拼成
`[len_lo len_hi] + 35B(CF01 记录)` 后 vhal 报错消失 —— 信封已通。

用法
----
  python3 Gemini-Dummy/tools/vhal_probe.py identity
  python3 Gemini-Dummy/tools/vhal_probe.py hex 2300cf014041...
  python3 Gemini-Dummy/tools/vhal_probe.py listen --seconds 5

回包（ACK / 属性广播）是应用级信号：guest 收到 ride-info 后会重新广播自身属性。
"""
import argparse
import os
import socket
import time

MAGIC = bytes([0xFE, 0x5A, 0xAA, 0xA5])
TAIL = bytes([0xA5, 0x55, 0x5A])

FRAME0_PROP = 0x11
FRAME1_PROP = 0x02
CMD_PROP = 0x00010175

KEYWORDS = ("vhal", "illegel", "ride_info", "mcucom", "[CFCP]", "parse_prop")

# guest 广播的已知属性（取自长期记忆）
KNOWN_PROPS = {
    0x21407072: "灯态位图",
    0x21709702: "档位",
    0x21707701: "状态",
}


def build_frame(frame0, frame1, cmd, data):
    body = bytearray()
    body.append(frame0 & 0xFF)
    body.append(frame1 & 0xFF)
    body += cmd.to_bytes(4, "little")
    body += len(data).to_bytes(2, "little")
    body += bytes(data)
    chk = (~sum(body)) & 0xFF
    return MAGIC + bytes(body) + bytes([chk]) + TAIL


def vhal_elem(payload):
    """按已解出的布局把一段载荷包成 vhal 数组元素。"""
    return bytes([len(payload) & 0xFF, (len(payload) >> 8) & 0xFF]) + bytes(payload)


def parse_frames(buf):
    """从字节流里切出完整 CFCP 帧，返回 (frames, 剩余)。"""
    out = []
    while True:
        i = buf.find(MAGIC)
        if i < 0:
            return out, b""
        buf = buf[i:]
        if len(buf) < 16:
            return out, buf
        data_len = int.from_bytes(buf[10:12], "little")
        total = 12 + data_len + 1 + 3
        if total > 1024 or len(buf) < total:
            return out, buf
        raw = buf[:total]
        chk_ok = (sum(raw[4:12 + data_len]) + raw[12 + data_len]) & 0xFF == 0xFF
        tail_ok = raw[-3:] == TAIL
        out.append({
            "frame0": raw[4],
            "frame1": raw[5],
            "cmd": int.from_bytes(raw[6:10], "little"),
            "data": raw[12:12 + data_len],
            "ok": chk_ok and tail_ok,
        })
        buf = buf[total:]


def describe(fr):
    d = fr["data"]
    kind = "ACK" if fr["frame0"] == 0x90 else f"type={fr['frame0']:02x}"
    extra = ""
    if fr["frame0"] == FRAME0_PROP and len(d) >= 10:
        inner = int.from_bytes(d[0:2], "little")
        prop = int.from_bytes(d[2:6], "little")
        sub = int.from_bytes(d[6:10], "little")
        value = d[10:]
        name = KNOWN_PROPS.get(prop, "")
        if len(value) == 4:
            val = int.from_bytes(value, "little")
        elif len(value) == 2:
            val = int.from_bytes(value, "little")
        else:
            val = repr(value[:12])
        extra = (f" prop=0x{prop:08x}" + (f"({name})" if name else "")
                 + f" sub={sub} value={val}")
    elif d:
        extra = f" data={d[:12].hex()}"
    return (f"{kind} cmd=0x{fr['cmd']:08x} {len(d)}B"
            f"{'' if fr['ok'] else ' [校验/尾不符]'}{extra}")


def log_size(path):
    try:
        return os.path.getsize(path)
    except OSError:
        return 0


def new_lines(path, offset, only_keywords=True, limit=30):
    try:
        with open(path, "rb") as f:
            f.seek(offset)
            raw = f.read()
    except OSError:
        return []
    lines = [ln.rstrip() for ln in raw.decode("utf-8", "replace").splitlines() if ln.strip()]
    if only_keywords:
        lines = [ln for ln in lines if any(k in ln for k in KEYWORDS)]
    return lines[-limit:]


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("mode", choices=["identity", "hex", "elem", "listen"])
    ap.add_argument("payload", nargs="?", default="")
    ap.add_argument("--port", type=int, default=9123)
    ap.add_argument("--log", default="/tmp/ui-serial.log")
    ap.add_argument("--seconds", type=float, default=3.0)
    ap.add_argument("--size", type=int, default=64)
    ap.add_argument("--frame0", type=lambda x: int(x, 0), default=FRAME0_PROP)
    ap.add_argument("--frame1", type=lambda x: int(x, 0), default=FRAME1_PROP)
    ap.add_argument("--cmd", type=lambda x: int(x, 0), default=CMD_PROP)
    ap.add_argument("--all", action="store_true")
    args = ap.parse_args()

    off = log_size(args.log)
    data = None
    if args.mode == "identity":
        data = bytes(range(args.size))
    elif args.mode == "hex":
        data = bytes.fromhex(args.payload.replace(" ", ""))
    elif args.mode == "elem":
        data = vhal_elem(bytes.fromhex(args.payload.replace(" ", "")))

    s = socket.create_connection(("127.0.0.1", args.port), timeout=5)
    s.settimeout(0.3)

    if data is not None:
        frame = build_frame(args.frame0, args.frame1, args.cmd, data)
        print(f"→ 发送 DATA={len(data)}B frame0=0x{args.frame0:02x} "
              f"cmd=0x{args.cmd:08x}  {data[:20].hex()}"
              f"{'…' if len(data) > 20 else ''}")
        s.sendall(frame)

    print(f"← 监听 {args.seconds:g}s …")
    buf = b""
    frames = []
    end = time.time() + args.seconds
    while time.time() < end:
        try:
            chunk = s.recv(4096)
        except socket.timeout:
            continue
        except OSError:
            break
        if not chunk:
            break
        buf += chunk
        got, buf = parse_frames(buf)
        for fr in got:
            frames.append(fr)
            print("  " + describe(fr))
    s.close()

    if not frames:
        print("  （没有任何回包 —— 链路或帧未被接受）")

    lines = new_lines(args.log, off, only_keywords=not args.all)
    if lines:
        print("内核/应用日志：")
        for ln in lines:
            print("  │ " + ln)


if __name__ == "__main__":
    main()
