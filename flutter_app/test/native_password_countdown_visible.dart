// Real-QEMU acceptance: the firmware's NATIVE top-right countdown is visible
// and drives the shutdown by itself (bit5 = shutdown_notify).
//
// Static reverse of PasswordUL (libdashclustoractivity.so):
//   ctor                       -> QTimer#1->start(20000)
//   slot_restartTimeout (20s)  -> stop #1; QTimer#2->start(1000); [this+0x1ec]=1
//   slot_downCountTimeout (1s) -> [this+0x1f0] 10..0; at 0 stop + tailcall
//   paintEvent                 -> if ([0x1ec]) draw QString::number([0x1f0])
//   countdown end              -> Power_On_Passwd byte[4] bit5 (0x20) to MCU
//
// MCU grace is 120s here so the MCU can NOT preempt the firmware sequence.
// Frames are captured at 21/25/29s (must differ: 10S..1S) and the run must end
// with the firmware's bit5 shutdown, which the client turns into a normal
// power-off.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:ae5i_emu/emu/controller.dart';
import 'package:ae5i_emu/emu/vehicle.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> until(bool Function() f, {int seconds = 60}) async {
  final end = DateTime.now().add(Duration(seconds: seconds));
  while (!f()) {
    if (DateTime.now().isAfter(end)) throw TimeoutException('visible-countdown probe timeout');
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('firmware native countdown visible and ends with bit5 shutdown', () async {
    final c = QemuController(
      passwordAutoShutdownDelay: const Duration(seconds: 120),
    );
    final dir = Directory('../dist/password-countdown-visible')..createSync(recursive: true);
    final out = File('${dir.path}/serial.log').openWrite();
    final lines = <String>[];
    ui.Image? frame;
    final logs = c.log.stream.listen((l) {
      lines.add(l.text);
      out.writeln('[${l.kind.name}] ${l.text}');
    });
    final frames = c.frames.stream.listen((f) {
      frame?.dispose();
      frame = f;
    });
    Future<Uint8List?> snapBytes(String name) async {
      final data = await frame?.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) return null;
      final bytes = data.buffer.asUint8List();
      File('${dir.path}/$name.png').writeAsBytesSync(bytes);
      return bytes;
    }

    try {
      c.setMcuPin('1234');
      await c.powerOn();
      await c.longPressReady();
      await until(() => c.vehicle.state == VehicleState.locked, seconds: 90);
      final t0 = DateTime.now();
      await Future<void>.delayed(const Duration(seconds: 1));

      final shots = <int, Uint8List?>{};
      shots[0] = await snapBytes('00-page');
      for (final sec in [21, 25, 29]) {
        final wait = sec - DateTime.now().difference(t0).inSeconds;
        if (wait > 0) await Future<void>.delayed(Duration(seconds: wait));
        shots[sec] = await snapBytes('${sec.toString().padLeft(2, '0')}s');
      }

      // 右上角倒计时 10S→…→1S：帧必须发生变化。
      expect(shots[21], isNotNull);
      expect(shots[21], isNot(equals(shots[25])), reason: 'countdown must visibly change 21s→25s');
      expect(shots[25], isNot(equals(shots[29])), reason: 'countdown must visibly change 25s→29s');

      // 归零后固件必须自己发 bit5，而不是 MCU 兜底。
      await until(() => lines.any((l) => l.contains('bits=0x20')), seconds: 45);
      expect(lines.any((l) => l.contains('固件 shutdown_notify')), true,
          reason: 'countdown end must arrive as firmware shutdown_notify (bit5)');
      await until(() => !c.running.value, seconds: 45);
    } finally {
      await c.stop();
      await logs.cancel();
      await out.close();
      await frames.cancel();
      frame?.dispose();
      c.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 6)));
}
