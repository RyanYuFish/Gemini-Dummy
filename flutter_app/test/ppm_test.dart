// Verifies the screendump PPM parser against a real QEMU capture when present,
// plus synthetic edge cases. Runs headless: `flutter test`.
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:ae5i_emu/main.dart';

List<int> _ppm(int w, int h, List<int> rgb) {
  final header = 'P6\n$w $h\n255\n'.codeUnits;
  return [...header, ...rgb];
}

void main() {
  test('parses a 2x2 PPM and converts RGB to opaque RGBA', () {
    final bytes = _ppm(2, 2, [
      255, 0, 0, // red
      0, 255, 0, // green
      0, 0, 255, // blue
      10, 20, 30,
    ]);
    final img = parsePpm(Uint8List.fromList(bytes));
    expect(img, isNotNull);
    expect(img!.width, 2);
    expect(img.height, 2);
    expect(img.rgba.length, 2 * 2 * 4);
    expect(img.rgba.sublist(0, 4), [255, 0, 0, 255]);
    expect(img.rgba.sublist(4, 8), [0, 255, 0, 255]);
    expect(img.rgba.sublist(8, 12), [0, 0, 255, 255]);
    expect(img.rgba.sublist(12, 16), [10, 20, 30, 255]);
  });

  test('rejects non-P6 and truncated payloads', () {
    expect(
      parsePpm(Uint8List.fromList('P3\n1 1\n255\n1 2 3'.codeUnits)),
      isNull,
    );
    final truncated = _ppm(4, 4, List.filled(4 * 4 * 3 - 5, 0));
    expect(parsePpm(Uint8List.fromList(truncated)), isNull);
  });

  test('parses a real framebuffer capture when available', () {
    const p = '/tmp/ae5i-ui-frame.ppm';
    if (!File(p).existsSync()) {
      // no capture on this machine; parser already covered above
      return;
    }
    final img = parsePpm(File(p).readAsBytesSync());
    expect(img, isNotNull);
    expect(img!.width, greaterThan(0));
    expect(img.height, greaterThan(0));
    expect(img.rgba.length, img.width * img.height * 4);
  });
}
