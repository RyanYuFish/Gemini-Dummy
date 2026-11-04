#!/usr/bin/env python3
"""Send a raw key ID to the AE5I guest's CFCP driver via the UART1 socket.

Symbolic names refer to AE5I Launcher key actions, derived from its Qt keymap
and KeyDelegate. The wiring diagram does not specify physical key IDs.
Run guest_shell.py with SP_CFCP_PORT first.
"""
import argparse
import socket
import struct
import time

HEADER = bytes.fromhex("fe5aaaa5")
TAIL = bytes.fromhex("a5555a")
# keymap.data -> Qt key -> KeyDelegate::keyPressEvent action.
KEY_ACTIONS = {"up": 0xd2, "down": 0xd3, "left": 0xd5,
               "right": 0xd4, "fn": 0xd1}


def parse_key(value):
    if value.lower() in KEY_ACTIONS:
        return KEY_ACTIONS[value.lower()]
    try:
        return int(value, 0)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("use a numeric ID or up/down/left/right/fn") from exc


def key_frame(key_id, pressed):
    if not 0 <= key_id <= 0xffffffff or pressed not in (0, 1):
        raise ValueError("invalid key ID or state")
    # rcar-taurus-cfcp.ko: is_filter accepts cmd 03 01 01 00 and
    # key_handle passes the two little-endian u32 words to the keypad driver.
    # AE5I cfcp_key_value_report maps 1 -> EV_KEY press, 3 -> release;
    # value 0 is ignored (it is not the Linux EV_KEY value).
    value = 1 if pressed else 3
    body = bytes.fromhex("100003010100") + struct.pack("<HII", 8, key_id, value)
    return HEADER + body + bytes([~sum(body) & 0xff]) + TAIL


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("key_id", type=parse_key,
                        help="numeric CFCP ID or Launcher action: up/down/left/right/fn")
    parser.add_argument("--port", type=int, default=4502)
    parser.add_argument("--hold", type=float, default=0.15,
                        help="seconds between press and release")
    args = parser.parse_args()
    if not 0 <= args.hold <= 60:
        parser.error("--hold must be between 0 and 60 seconds")
    with socket.create_connection(("127.0.0.1", args.port), timeout=5) as conn:
        conn.sendall(key_frame(args.key_id, 1))
        time.sleep(args.hold)
        conn.sendall(key_frame(args.key_id, 0))
    print(f"sent CFCP key ID 0x{args.key_id:x}: press, release")


if __name__ == "__main__":
    main()
