#!/usr/bin/env python3
"""诊断：发送基线+KL15+vehicle_info1，把 guest 回包存盘并解析出广播的属性 id。

回包按 CFCP 属性帧解：搜 MAGIC fe5aaaa5 ... a5555a，抽 [inner u16][prop u32][sub u32][value]。
"""
import socket, struct, sys, time

MAGIC = bytes([0xFE, 0x5A, 0xAA, 0xA5])
TAIL = bytes([0xA5, 0x55, 0x5A])
CMD_PROP = 0x00010175


def build(f0, f1, cmd, data):
    body = bytearray([f0 & 0xFF, f1 & 0xFF])
    body += cmd.to_bytes(4, "little")
    body += len(data).to_bytes(2, "little")
    body += bytes(data)
    return MAGIC + bytes(body) + bytes([(~sum(body)) & 0xFF]) + TAIL


def prop_frame(prop, sub, value):
    inner = 4 + 4 + len(value)
    data = struct.pack("<HH", inner, prop & 0xFFFF)
    data += struct.pack("<H", (prop >> 16) & 0xFFFF)
    data += struct.pack("<I", sub & 0xFFFFFFFF)
    data += bytes(value)
    return build(0x11, 0x02, CMD_PROP, data)


def prop_int(prop, sub, v):
    return prop_frame(prop, sub, struct.pack("<I", v & 0xFFFFFFFF))


def prop_raw(prop, sub, v):
    return prop_frame(prop, sub, bytes(v))


def main():
    frames = []
    frames.append(prop_frame(0x21701002, 0, b"SW.1.00.56 AE5I".ljust(24, b"\x00")))
    frames.append(prop_int(0x21417310, 0, 1))
    frames.append(prop_int(0x27407404, 0, 0xFFFFFFFF))
    frames.append(prop_int(0x21707701, 0, 0xC0))
    frames.append(prop_raw(0x21709702, 0, [8, 0]))
    frames.append(prop_int(0x21709521, 0, 0))
    frames.append(prop_int(0x21407072, 0, 0))
    frames.append(prop_int(0x21400030, 0, 0x99))   # KL15
    vi1 = bytearray(20)
    struct.pack_into("<i", vi1, 0, 250)
    struct.pack_into("<i", vi1, 12, 3000)
    struct.pack_into("<i", vi1, 16, 80)
    frames.append(prop_raw(0x21707402, 0, vi1))

    s = socket.create_connection(("127.0.0.1", 9123), timeout=5)
    s.settimeout(0.4)
    for f in frames:
        s.sendall(f)
        time.sleep(0.05)
    buf = b""
    end = time.time() + 2.0
    while time.time() < end:
        try:
            c = s.recv(4096)
        except socket.timeout:
            continue
        except OSError:
            break
        if not c:
            break
        buf += c
    s.close()
    with open("/tmp/reply.bin", "wb") as f:
        f.write(buf)
    print(f"回包 {len(buf)} 字节 → /tmp/reply.bin")

    # 解析所有 CFCP 属性帧
    off = 0
    hits = []
    while True:
        i = buf.find(MAGIC, off)
        if i < 0:
            break
        j = buf.find(TAIL, i)
        if j < 0:
            break
        frame = buf[i:j + 3]
        off = j + 3
        # frame = MAGIC(4) [f0 f1 cmd(4) len(2) data] chk(1) TAIL(3)
        if len(frame) < 4 + 2 + 4 + 2 + 1 + 3:
            continue
        f0, f1 = frame[4], frame[5]
        cmd = struct.unpack("<I", frame[6:10])[0]
        dlen = struct.unpack("<H", frame[10:12])[0]
        data = frame[12:12 + dlen]
        if len(data) < 10:
            continue
        inner, pl = struct.unpack("<HH", data[0:4])
        ph = struct.unpack("<H", data[4:6])[0]
        prop = pl | (ph << 16)
        sub = struct.unpack("<I", data[6:10])[0]
        value = data[10:]
        hits.append((f0, f1, cmd, prop, sub, value))
    print(f"解析到 {len(hits)} 个 CFCP 属性帧：")
    for f0, f1, cmd, prop, sub, value in hits:
        vhex = value.hex()
        print(f"  f0={f0:#04x} f1={f1:#04x} cmd={cmd:#010x} prop={prop:#010x} sub={sub:#010x} value={vhex}")


if __name__ == "__main__":
    main()
