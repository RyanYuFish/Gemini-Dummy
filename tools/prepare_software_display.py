#!/usr/bin/env python3
"""Build a QEMU-only SPVD with a DirectFB diagnostic profile.

Never produces an OTA pack. The source SPVD and factory dump stay unchanged.
Only init.environ.rc changes; the original AE5I kernel and Qt binaries are used.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile

LAB = Path(__file__).resolve().parents[1]
OUT = LAB.parent / "dist/qemu-ae5i"


def prepare(source, output, profile="software"):
    source, output = source.resolve(), output.resolve()
    if source == output or not output.is_relative_to(OUT.resolve()):
        raise ValueError("output must be a new SPVD under dist/qemu-ae5i")
    output.parent.mkdir(parents=True, exist_ok=True)
    with source.open("rb") as src:
        header = src.read(4096)
        if header[:8] != b"SPVD\x01\0\0\0":
            raise ValueError("expected SPVD v1")
        data_offset = struct.unpack_from("<I", header, 0x1c)[0]
        count = struct.unpack_from("<I", header, 0x2c)[0]
        parts = {}
        for i in range(count):
            name, start, size, _ = struct.unpack_from("<32sIII", header, 0x400 + 44 * i)
            parts[name.rstrip(b"\0").decode()] = (start, size)
        start, size = parts["rootfs."]
        src.seek(data_offset + start)
        rootfs = src.read(size)
    with tempfile.TemporaryDirectory(dir=output.parent) as tmp:
        tmp = Path(tmp)
        original = tmp / "original.sqsh"
        original.write_bytes(rootfs)
        tree = tmp / "rootfs"
        subprocess.run(["unsquashfs", "-d", str(tree), str(original)], check=True,
                       stdout=subprocess.DEVNULL)
        rc = tree / "init.environ.rc"
        config = rc.read_text()
        needle = "export DFBARGS "
        lines = config.splitlines()
        changed = 0
        for i, line in enumerate(lines):
            if line.strip().startswith(needle):
                lines[i] += ",no-vt,no-vt-switch,vsync-none,no-flip-wait,no-quiet"
                if profile == "software":
                    lines[i] += ",no-hardware,disable-module=gal"
                changed += 1
        if changed != 1:
            raise ValueError("expected exactly one DFBARGS export")
        rc.write_text("\n".join(lines) + "\n")
        sqsh = tmp / "software.sqsh"
        subprocess.run(["mksquashfs", str(tree), str(sqsh), "-noappend", "-comp", "lzo",
                        "-b", "131072", "-all-root", "-no-progress"], check=True,
                       stdout=subprocess.DEVNULL)
        payload = sqsh.read_bytes()
        if len(payload) > size:
            raise ValueError("rootfs exceeds partition")
        stage = tmp / "software.spvd"
        shutil.copyfile(source, stage)
        with stage.open("r+b") as dst:
            dst.seek(data_offset + start)
            dst.write(payload)
            dst.write(b"\xff" * (size - len(payload)))
        stage.replace(output)
    report = {"source": str(source), "output": str(output),
              "rootfs_offset": start, "rootfs_size": len(payload),
              "source_rootfs_sha256": hashlib.sha256(rootfs).hexdigest(),
              "software_rootfs_sha256": hashlib.sha256(payload).hexdigest(),
              "changes": [f"init.environ.rc: DFBARGS {profile} profile; no VT/vsync wait"],
              "purpose": "QEMU-only SPVD; not an OTA/flashable pack"}
    output.with_suffix(".json").write_text(json.dumps(report, indent=2) + "\n")
    print(output)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=LAB / "images/ae5i.spvd")
    parser.add_argument("--output", type=Path, default=OUT / "ae5i-software.spvd")
    parser.add_argument("--profile", choices=("software", "gal"), default="software",
                        help="software fallback (default), or experimental gal driver")
    args = parser.parse_args()
    if args.profile == "gal" and args.output == OUT / "ae5i-software.spvd":
        parser.error("specify a separate --output for the gal profile")
    prepare(args.source, args.output, args.profile)
