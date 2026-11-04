// 二进制 PPM(P6) 解码 —— QEMU monitor `screendump` 的输出格式。
// 纯函数，可在无显示环境里单测。

import 'dart:typed_data';

class PpmImage {
  final int width;
  final int height;
  final Uint8List rgba;
  const PpmImage(this.width, this.height, this.rgba);
}

PpmImage? parsePpm(Uint8List b) {
  if (b.length < 15 || b[0] != 0x50 || b[1] != 0x36) return null;
  var i = 2;
  final vals = <int>[];
  while (vals.length < 3 && i < b.length) {
    while (i < b.length &&
        (b[i] == 0x20 || b[i] == 0x0a || b[i] == 0x0d || b[i] == 0x09)) {
      i++;
    }
    var v = 0;
    var got = false;
    while (i < b.length && b[i] >= 0x30 && b[i] <= 0x39) {
      v = v * 10 + (b[i] - 0x30);
      i++;
      got = true;
    }
    if (got) vals.add(v);
  }
  if (vals.length < 3) return null;
  i++; // single whitespace after maxval
  final w = vals[0], h = vals[1];
  final need = w * h * 3;
  if (w <= 0 || h <= 0 || b.length - i < need) return null;

  final rgba = Uint8List(w * h * 4);
  var s = i, d = 0;
  for (var p = 0; p < w * h; p++) {
    rgba[d++] = b[s++];
    rgba[d++] = b[s++];
    rgba[d++] = b[s++];
    rgba[d++] = 0xff;
  }
  return PpmImage(w, h, rgba);
}
