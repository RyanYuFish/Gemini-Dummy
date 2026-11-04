#!/usr/bin/env python3
"""Build the power-on animation blob from the device's own anm_logo partition.

Why this exists
---------------
On the real instrument the ZEEHO logo animation is played by the *bootloader*
stage together with the PFC "PE" decode hardware, long before Linux starts:
`anm_logo` holds a PART container with logo.mkv (H.264, 1024x600, 60 fps,
112 frames), the eCos side starts playback, and userspace only ever calls
`PlatformControl::Stop_Animation_Logo()` once the Launcher has a frame ready.

Our machine model starts at the Linux kernel with no PE block, so nothing is
ever decoded and the panel stays black from power-on until the Qt UI appears.
This tool pre-decodes the firmware's own asset so the model can stand in for
that missing hardware: frames are original device content, not drawn by us.

Output format (little endian)
-----------------------------
    "ANM2" | u32 version(=2) | u32 frames | u32 w | u32 h | u32 fps
    index: frames x { u32 offset, u32 length }   (relative to data_off)
    u32 data_off
    payload: run-length coded RGB565LE frames, in order

One run is `u16 value | u8 count` (count 1..255, 0 terminates a frame early).
RLE and not zlib on purpose: the model links no zlib, and a 3-byte run is
cheap enough to expand in C (measured 3.4 MiB for all 112 frames, 31 KiB per
frame on average, 81 KiB worst case).  RGB565 keeps the logo's flat white on
black exact after the 5/6-bit round trip the panel does anyway.

Usage
-----
    python3 tools/make_bootanim.py                    # auto: images/ae5i.spvd
    python3 tools/make_bootanim.py --spvd X --out Y
"""
import argparse
import os
import re
import struct
import subprocess
import sys
import tempfile

LAB = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# From the device's own mtdparts (env partition), all offsets are NAND data
# offsets; the SPVD stores page data only, behind a 0x1000 header.
ANM_LOGO_OFF = 0xA9C0000
SPVD_HDR = 0x1000

DEFAULT_SPVD = os.path.join(LAB, "images", "ae5i.spvd")
DEFAULT_OUT = os.path.join(os.path.dirname(LAB), "dist", "qemu-ae5i",
                           "anm_logo.bin")


EBML_MAGIC = b"\x1a\x45\xdf\xa3"


def extract_logo_mkv(spvd):
    """Pull logo.mkv out of the PART container that starts anm_logo.

    Measured layout of the single record (hexdump of the real partition):

        0x00  "PART"
        0x04  u32 total_size    = 0xda90
        0x08  u32 0x10
        0x0c  u32 0x20
        0x10  char name[24]     = "logo.mkv" + NUL padding
        0x28  u32 data_size     = 0xda5c
        0x2c  u32 data_offset   = 0x30
        0x30  payload (Matroska), 0xda5c bytes
        0xda8c u32 trailer, so total = 0x30 + 0xda5c + 4

    Rather than trust the two unknown u32 at 0x08/0x0c, locate the payload by
    its EBML magic and read the length from the u32 eight bytes before it.
    """
    with open(spvd, "rb") as f:
        f.seek(SPVD_HDR + ANM_LOGO_OFF)
        head = f.read(0x100)
        if head[:4] != b"PART":
            raise SystemExit(f"anm_logo @{ANM_LOGO_OFF:#x} is not a PART "
                             f"container (magic {head[:4]!r})")
        total = struct.unpack_from("<I", head, 0x04)[0]
        rel = head.find(EBML_MAGIC)
        if rel <= 8:
            raise SystemExit("no Matroska payload inside the PART record")
        size, offset = struct.unpack_from("<II", head, rel - 8)
        if offset != rel:
            raise SystemExit(f"PART record inconsistent: offset field "
                             f"{offset:#x} but payload found at {rel:#x}")
        name = head[0x10:rel - 8].split(b"\x00")[0].decode("latin1")
        if rel + size > total:
            raise SystemExit(f"PART record overruns its total "
                             f"({rel:#x}+{size:#x} > {total:#x})")
        f.seek(SPVD_HDR + ANM_LOGO_OFF + rel)
        data = f.read(size)
    if data[:4] != EBML_MAGIC:
        raise SystemExit("extracted payload is not Matroska")
    return name, data


def rle16(frame):
    """RLE a raw RGB565LE frame into `u16 value | u8 count` runs.

    The regex finds maximal runs of one repeated 2-byte group in C speed; runs
    longer than 255 pixels are then split.  Callers must verify with
    rle16_decode() -- a run that straddles an odd byte boundary would still
    match here but decode wrongly.
    """
    out = bytearray()
    for m in re.finditer(rb"(..)\1*", frame, re.S):
        v = m.group(1)
        left = len(m.group(0)) // 2
        while left > 0:
            take = min(left, 255)
            out += v + bytes((take,))
            left -= take
    return bytes(out)


def rle16_decode(blob, pixels):
    """Expand rle16() output back to raw RGB565LE (used as a self check)."""
    out = bytearray()
    i = 0
    while i + 2 < len(blob) and len(out) // 2 < pixels:
        n = blob[i + 2]
        if not n:
            break
        out += blob[i:i + 2] * n
        i += 3
    return bytes(out)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--spvd", default=DEFAULT_SPVD)
    ap.add_argument("--out", default=DEFAULT_OUT)
    ap.add_argument("--fps", type=int, default=0,
                    help="override the source frame rate")
    args = ap.parse_args()

    if not os.path.exists(args.spvd):
        raise SystemExit(f"SPVD not found: {args.spvd}")
    name, mkv = extract_logo_mkv(args.spvd)
    print(f"anm_logo: {name}, {len(mkv)} bytes")

    with tempfile.TemporaryDirectory() as tmp:
        mkv_path = os.path.join(tmp, "logo.mkv")
        with open(mkv_path, "wb") as f:
            f.write(mkv)
        probe = subprocess.run(
            ["ffprobe", "-v", "error", "-select_streams", "v:0",
             "-show_entries", "stream=width,height,r_frame_rate",
             "-of", "csv=p=0", mkv_path],
            capture_output=True, text=True, check=True)
        w, h, rate = probe.stdout.strip().split(",")
        w, h = int(w), int(h)
        num, _, den = rate.partition("/")
        fps = args.fps or max(1, round(int(num) / int(den or 1)))
        print(f"video: {w}x{h} @ {fps} fps")

        raw = os.path.join(tmp, "frames.raw")
        subprocess.run(
            ["ffmpeg", "-v", "error", "-y", "-i", mkv_path,
             "-pix_fmt", "rgb565le", "-f", "rawvideo", raw],
            check=True)
        with open(raw, "rb") as f:
            data = f.read()

    frame_bytes = w * h * 2
    frames = len(data) // frame_bytes
    if frames == 0:
        raise SystemExit("no frames decoded")
    if len(data) % frame_bytes:
        print(f"warning: trailing {len(data) % frame_bytes} bytes ignored")

    blobs = []
    for i in range(frames):
        frame = data[i * frame_bytes:(i + 1) * frame_bytes]
        blob = rle16(frame)
        if rle16_decode(blob, w * h) != frame:
            raise SystemExit(f"frame {i}: RLE round trip mismatch")
        blobs.append(blob)

    hdr_size = 24 + frames * 8 + 4
    index = bytearray()
    off = 0
    for b in blobs:
        index += struct.pack("<II", off, len(b))
        off += len(b)

    out_dir = os.path.dirname(args.out)
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)
    with open(args.out, "wb") as f:
        f.write(b"ANM2")
        f.write(struct.pack("<IIIII", 2, frames, w, h, fps))
        f.write(index)
        f.write(struct.pack("<I", hdr_size))
        for b in blobs:
            f.write(b)

    total = hdr_size + off
    print(f"wrote {args.out}: {frames} frames, {w}x{h} @ {fps} fps, "
          f"{total / 1048576:.2f} MiB "
          f"(avg {off / frames / 1024:.0f} KiB/frame)")


if __name__ == "__main__":
    sys.exit(main())
