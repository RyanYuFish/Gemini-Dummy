#!/usr/bin/env python3
"""探测某个 prop id 是否被 libmcucommodule 的某个 rx handler 消费。

用法: python3 probe_prop.py 0x21707403 0x21707404 ...
      （每个 prop 以「第 i 字节 = i」的身份载荷发一次 20B 向量，
       guest 侧 handler 的日志会回显它解析出的字段值。）
"""
import socket
import struct
import sys
import time

MAGIC = b"\xfe\x5a\xaa\xa5"
TAIL = b"\xa5\x55\x5a"
ACK = bytes([0xFE, 0x5A, 0xAA, 0xA5, 0x90, 0x08, 0x55, 0x01, 0x01, 0x00, 0x00, 0x00, 0x10, 0xA5, 0x55, 0x5A])


def build(frame0, frame1, cmd, data):
    body = bytearray([frame0 & 0xFF, frame1 & 0xFF])
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
    return build(0x11, 0x02, 0x00010175, data)


def main():
    props = [int(x, 16) for x in sys.argv[1:]] or [0x21707403, 0x21707404]
    s = socket.create_connection(("127.0.0.1", 9123), timeout=5)
    s.setblocking(False)
    ident = bytes(range(20))
    for p in props:
        s.sendall(prop_frame(p, 0, ident))
        time.sleep(0.25)
    # drain + ack for a moment
    end = time.time() + 1.5
    while time.time() < end:
        try:
            c = s.recv(8192)
        except (BlockingIOError, socket.timeout):
            time.sleep(0.02)
            continue
        except OSError:
            break
        if not c:
            break
        if c.find(MAGIC) >= 0:
            try:
                s.sendall(ACK)
            except OSError:
                pass
    s.close()
    print("sent", [hex(p) for p in props])


if __name__ == "__main__":
    main()
