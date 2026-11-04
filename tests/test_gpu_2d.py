#!/usr/bin/env python3
"""Exercise the SP8368 GPU command processor through QEMU's qtest protocol."""
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest

QEMU = Path(__file__).resolve().parents[1] / "qemu-src/build/qemu-system-arm"
GPU = 0x9c110000
COMMAND = 0x100000
SURFACE = 0x200000


class GPU2DTest(unittest.TestCase):
    def setUp(self):
        env = dict(os.environ)
        env.pop("SP_GPU_TRACE", None)
        env["SP_GPU_EXPERIMENTAL_GC320"] = "1"
        if self._testMethodName == "test_experimental_multi_framebuffer_reply":
            env["SP_FB_MULTI"] = "1"
            env["SP_IPC_STUB"] = "1"
        if self._testMethodName in ("test_live_frame_snapshot",
                                   "test_fb_scanout_after_many_swaps",
                                   "test_fb_window_snapshot"):
            temp = tempfile.TemporaryDirectory()
            self.addCleanup(temp.cleanup)
            self.frame = Path(temp.name) / "frame.ppm"
            env["SP_FB_FRAME"] = str(self.frame)
            env["SP_IPC_STUB"] = "1"
            if self._testMethodName == "test_fb_window_snapshot":
                env["SP_FB_WINDOW"] = "1"
        self.qemu = subprocess.Popen(
            [str(QEMU), "-M", "sunplus-sp8368,accel=qtest", "-m", "256",
             "-display", "none", "-serial", "null", "-monitor", "none",
             "-qtest", "stdio"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, text=True, env=env)

    def tearDown(self):
        self.qemu.terminate()
        self.qemu.communicate(timeout=5)

    def command(self, command):
        self.qemu.stdin.write(command + "\n")
        self.qemu.stdin.flush()
        response = self.qemu.stdout.readline().strip()
        self.assertTrue(response.startswith("OK"), response)
        return response

    def write_bytes(self, addr, data):
        self.command(f"write 0x{addr:x} 0x{len(data):x} 0x{data.hex()}")

    def read_bytes(self, addr, length):
        return bytes.fromhex(self.command(f"read 0x{addr:x} 0x{length:x}").split()[1][2:])

    def execute(self, config, src_origin=0, command_addr=COMMAND,
                surface_addr=SURFACE, source_addr=None, blend=False,
                indexed=False, premultiply=True, stretch=False, stretch_y=0x20000,
                global_alpha=False):
        states = [(0x1200, source_addr if source_addr is not None else surface_addr),
                  (0x1204, 64 if stretch else 8 if indexed else 32), (0x1208, 0),
                  (0x120c, 9 if indexed else 6), (0x1210, src_origin),
                  (0x1214, 0x00100010 if stretch else 0),
                  (0x1220, 0x20000 if stretch else 0),
                  (0x1224, stretch_y if stretch else 0),
                  (0x1228, surface_addr), (0x122c, 32), (0x1230, 0),
                  (0x1234, config), (0x1260, 0x00010001),
                  (0x125c, 0x00cc), (0x1264, 0x00070007),
                  (0x127c, 0x00ff0001 if global_alpha else int(blend)),
                  (0x1280, 0x31000200 if global_alpha else 0x31000000 if blend else 0),
                  (0x12c8, 0x80ffffff if global_alpha else 0),
                  (0x12d0, 0x101 if global_alpha else int(blend and premultiply)),
                  (0x12c0, 0xff336699)]
        words = []
        for addr, value in states:
            words.extend((0x08010000 | (addr >> 2), value))
        if indexed:
            palette = [0] * 256
            palette[3] = 0xff112233
            words.extend([0x09000d00, *palette, 0])
        words.extend((0x20000100, 0, 0, 0x00080008,
                      0x08010e01, 0x47, 0x10000000, 0))
        self.write_bytes(COMMAND, struct.pack("<" + "I" * len(words), *words))
        self.command(f"writel 0x{GPU + 0x654:x} 0x{command_addr:x}")
        self.command(f"writel 0x{GPU + 0x658:x} 0x{0x10000 | (len(words) // 2):x}")
        self.command("clock_step 1000000")

    def test_clear_clips_and_signals_after_writes(self):
        self.write_bytes(SURFACE, bytes(8 * 8 * 4))
        self.execute(6)  # linear A8R8G8B8 CLEAR
        data = self.read_bytes(SURFACE, 8 * 8 * 4)
        for y in range(8):
            for x in range(8):
                pixel = struct.unpack_from("<I", data, y * 32 + x * 4)[0]
                self.assertEqual(pixel, 0xff336699 if 1 <= x < 7 and 1 <= y < 7 else 0)
        self.assertEqual(int(self.command(f"readl 0x{GPU + 0x10:x}").split()[1], 16), 1 << 7)
        self.assertEqual(int(self.command(f"readl 0x{GPU + 0x10:x}").split()[1], 16), 0)

    def test_overlapping_blit_snapshots_clipped_source(self):
        original = struct.pack("<64I", *range(64))
        self.write_bytes(SURFACE, original)
        self.execute(6 | (2 << 12), src_origin=0x00010001)
        data = self.read_bytes(SURFACE, 8 * 8 * 4)
        for y in range(8):
            for x in range(8):
                expected = (y + 1) * 8 + x + 1 if 1 <= x < 7 and 1 <= y < 7 else y * 8 + x
                self.assertEqual(struct.unpack_from("<I", data, y * 32 + x * 4)[0], expected)
        self.assertEqual(int(self.command(f"readl 0x{GPU + 0x10:x}").split()[1], 16), 1 << 7)

    def test_source_over_blend(self):
        source = 0x210000
        self.write_bytes(SURFACE, struct.pack("<64I", *([0xff0000ff] * 64)))
        self.write_bytes(source, struct.pack("<64I", *([0x80ff0000] * 64)))
        self.execute(6 | (2 << 12), source_addr=source, blend=True)
        data = self.read_bytes(SURFACE, 8 * 8 * 4)
        self.assertEqual(struct.unpack_from("<I", data, 32 + 4)[0], 0xff80007f)
        self.assertEqual(struct.unpack_from("<I", data, 0)[0], 0xff0000ff)
        self.assertEqual(int(self.command(f"readl 0x{GPU + 0x10:x}").split()[1], 16), 1 << 7)

    def test_indexed_source_uses_uploaded_palette(self):
        source = 0x210000
        self.write_bytes(SURFACE, bytes(8 * 8 * 4))
        self.write_bytes(source, bytes([3] * 64))
        self.execute(6 | (2 << 12), source_addr=source, indexed=True)
        data = self.read_bytes(SURFACE, 8 * 8 * 4)
        self.assertEqual(struct.unpack_from("<I", data, 32 + 4)[0], 0xff112233)
        self.assertEqual(struct.unpack_from("<I", data, 0)[0], 0)
        self.assertEqual(int(self.command(f"readl 0x{GPU + 0x10:x}").split()[1], 16), 1 << 7)

    def test_source_over_blend_with_premultiplied_input(self):
        source = 0x210000
        self.write_bytes(SURFACE, struct.pack("<64I", *([0xff0000ff] * 64)))
        self.write_bytes(source, struct.pack("<64I", *([0x80800000] * 64)))
        self.execute(6 | (2 << 12), source_addr=source, blend=True, premultiply=False)
        data = self.read_bytes(SURFACE, 8 * 8 * 4)
        self.assertEqual(struct.unpack_from("<I", data, 32 + 4)[0], 0xff80007f)

    def test_source_over_with_global_alpha(self):
        source = 0x210000
        self.write_bytes(SURFACE, struct.pack("<64I", *([0xff0000ff] * 64)))
        self.write_bytes(source, struct.pack("<64I", *([0x80ff0000] * 64)))
        self.execute(6 | (2 << 12), source_addr=source, blend=True, global_alpha=True)
        data = self.read_bytes(SURFACE, 8 * 8 * 4)
        self.assertEqual(struct.unpack_from("<I", data, 32 + 4)[0], 0xff4000bf)

    def test_stretch_samples_nearest_source_with_clipping(self):
        source = 0x210000
        self.write_bytes(SURFACE, bytes(8 * 8 * 4))
        self.write_bytes(source, struct.pack("<256I", *range(256)))
        self.execute(6 | (4 << 12), source_addr=source, stretch=True)
        data = self.read_bytes(SURFACE, 8 * 8 * 4)
        for y in range(8):
            for x in range(8):
                expected = y * 32 + x * 2 if 1 <= x < 7 and 1 <= y < 7 else 0
                self.assertEqual(struct.unpack_from("<I", data, y * 32 + x * 4)[0], expected)
        self.assertEqual(int(self.command(f"readl 0x{GPU + 0x10:x}").split()[1], 16), 1 << 7)

    def test_stretch_zero_factor_repeats_source_row(self):
        source = 0x210000
        self.write_bytes(SURFACE, bytes(8 * 8 * 4))
        self.write_bytes(source, struct.pack("<256I", *range(256)))
        self.execute(6 | (4 << 12), source_addr=source, stretch=True, stretch_y=0)
        data = self.read_bytes(SURFACE, 8 * 8 * 4)
        self.assertEqual(struct.unpack_from("<I", data, 3 * 32 + 2 * 4)[0], 4)
        self.assertEqual(int(self.command(f"readl 0x{GPU + 0x10:x}").split()[1], 16), 1 << 7)

    def test_unsupported_filter_does_not_signal_completion(self):
        self.write_bytes(SURFACE, bytes(8 * 8 * 4))
        self.execute(6 | (5 << 12))
        self.assertEqual(self.read_bytes(SURFACE, 8 * 8 * 4), bytes(8 * 8 * 4))
        self.assertEqual(int(self.command(f"readl 0x{GPU + 0x10:x}").split()[1], 16), 0)

    def test_idle_wait_observes_guest_patch(self):
        self.write_bytes(COMMAND, struct.pack("<4I", 0x380000c8, 0, 0x40000002, COMMAND))
        self.command(f"writel 0x{GPU + 0x654:x} 0x{COMMAND:x}")
        self.command(f"writel 0x{GPU + 0x658:x} 0x10002")
        self.command("clock_step 1000000")
        self.assertEqual(int(self.command(f"readl 0x{GPU + 0x664:x}").split()[1], 16), COMMAND)
        self.write_bytes(COMMAND, struct.pack("<4I", 0x08010e01, 0x47, 0x10000000, 0))
        self.command("clock_step 2000000")
        self.assertEqual(int(self.command(f"readl 0x{GPU + 0x10:x}").split()[1], 16), 1 << 7)

    def test_gpu_page_table_translates_command_and_surface(self):
        table = 0x300000
        self.command(f"writel 0x{table + 5 * 4:x} 0x{COMMAND:x}")
        self.command(f"writel 0x{table + 10 * 4:x} 0x{SURFACE:x}")
        self.command(f"writel 0x{GPU + 0x400:x} 0x{table:x}")
        self.command(f"writel 0x{GPU + 0x408:x} 0x{table:x}")
        self.write_bytes(SURFACE, bytes(8 * 8 * 4))
        self.execute(6, command_addr=0x80005000, surface_addr=0x8000a000)
        data = self.read_bytes(SURFACE, 8 * 8 * 4)
        self.assertEqual(struct.unpack_from("<I", data, 32 + 4)[0], 0xff336699)
        self.assertEqual(int(self.command(f"readl 0x{GPU + 0x10:x}").split()[1], 16), 1 << 7)

    def test_live_frame_snapshot(self):
        self.command("writel 0x0c000000 0xff112233")
        self.command("clock_step 500000000")
        contents = self.frame.read_bytes()
        self.assertTrue(contents.startswith(b"P6\n800 480\n255\n\x11\x22\x33"))
        self.command("writel 0x0c000000 0xff445566")
        self.command("clock_step 250000000")
        self.assertTrue(self.frame.read_bytes().startswith(b"P6\n800 480\n255\n\x44\x55\x66"))
        self.assertFalse(self.frame.with_suffix(".ppm.tmp").exists())

    def test_fb_scanout_after_many_swaps(self):
        self.command("writel 0x0c000000 0xff112233")
        self.command("writel 0x0c177000 0xff445566")
        self.command("writel 0x9c008110 0xc0408000")  # kernel owner
        self.command("writel 0x9c008118 0x00060008")  # cmd 6, 8 bytes
        self.command("writel 0x9c008124 0")           # fb0 window
        for i in range(70):
            self.command(f"writel 0x9c008128 {i % 2}")
            self.command("writel 0x9c008100 1")
        self.command("clock_step 500000000")
        self.assertTrue(self.frame.read_bytes().startswith(b"P6\n800 480\n255\n\x44\x55\x66"))
        self.command("writel 0x9c008128 0")
        self.command("writel 0x9c008100 1")
        self.command("clock_step 250000000")
        self.assertTrue(self.frame.read_bytes().startswith(b"P6\n800 480\n255\n\x11\x22\x33"))

    def test_fb_window_snapshot(self):
        self.command("writel 0x0c977000 0xffa1b2c3")  # fb1 page 1
        self.command("writel 0x9c008110 0xc0408000")  # kernel owner
        self.command("writel 0x9c008118 0x00060008")  # cmd 6, 8 bytes
        self.command("writel 0x9c008124 1")           # fb1 window
        self.command("writel 0x9c008128 1")           # page 1
        self.command("writel 0x9c008100 1")
        self.command("clock_step 500000000")
        self.assertTrue(self.frame.read_bytes().startswith(b"P6\n800 480\n255\n\xa1\xb2\xc3"))

    def test_experimental_multi_framebuffer_reply(self):
        self.command("writel 0x9c008110 0xc0408000")
        self.command("writel 0x9c008118 0x00030174")
        self.command("writel 0x9c008128 0x00200000")
        self.command("writel 0x9c008100 1")
        payload = self.read_bytes(0x200000, 0x174)
        for i in range(3):
            selector, width, height, buffers = struct.unpack_from("<4I", payload, i * 0x7c)
            self.assertEqual((selector, width, height, buffers), (i, 800, 480, 2))


if __name__ == "__main__":
    unittest.main()
