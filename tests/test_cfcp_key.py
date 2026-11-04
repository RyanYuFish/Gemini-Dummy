#!/usr/bin/env python3
"""CFCP vectors observed through the AE5I kernel's cfcp-keypad driver."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location(
    "cfcp_key", Path(__file__).resolve().parents[1] / "tools/cfcp_key.py")
cfcp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cfcp)


class CFCPKeyTest(unittest.TestCase):
    def test_press_and_release_vectors(self):
        self.assertEqual(cfcp.key_frame(103, 1).hex(),
                         "fe5aaaa5100003010100080067000000010000007aa5555a")
        self.assertEqual(cfcp.key_frame(103, 0).hex(),
                         "fe5aaaa51000030101000800670000000300000078a5555a")

    def test_invalid_input_is_rejected(self):
        for key, state in ((-1, 1), (0x100000000, 1), (1, 2)):
            with self.assertRaises(ValueError):
                cfcp.key_frame(key, state)

    def test_launcher_actions_from_factory_keymap(self):
        self.assertEqual(cfcp.parse_key("up"), 0xd2)
        self.assertEqual(cfcp.parse_key("down"), 0xd3)
        self.assertEqual(cfcp.parse_key("0xd4"), 0xd4)


if __name__ == "__main__":
    unittest.main()
