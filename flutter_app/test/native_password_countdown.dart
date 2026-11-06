// Real-QEMU acceptance probe for the password-page idle auto-shutdown.
//
// Corrected flow (verified 2026-11-06): the firmware PasswordUL owns the whole
// sequence — 20s idle → 10s top-right countdown (10S..1S) → bit5
// (shutdown_notify) on Power_On_Passwd → controller normal power-off.
// The MCU grace (default 35s) is ONLY a fallback and must not fire first.
//
// This probe types no password and proves the idle page shuts the cluster down
// via the firmware's bit5, not via the MCU fallback.
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:ae5i_emu/emu/controller.dart';
import 'package:ae5i_emu/emu/vehicle.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> until(bool Function() f, {int seconds = 60}) async {
  final end = DateTime.now().add(Duration(seconds: seconds));
  while (!f()) {
    if (DateTime.now().isAfter(end)) throw TimeoutException('native countdown timeout');
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('idle password page auto-shuts-down without input', () async {
    final c = QemuController();
    final dir = Directory('../dist/password-countdown')..createSync(recursive: true);
    final out = File('${dir.path}/serial.log').openWrite();
    final lines = <String>[];
    ui.Image? frame;
    final logs = c.log.stream.listen((l) {
      lines.add(l.text);
      out.writeln('[${l.kind.name}] ${l.text}');
    });
    final frames = c.frames.stream.listen((f) { frame?.dispose(); frame = f; });
    Future<void> snap(String name) async {
      final data = await frame?.toByteData(format: ui.ImageByteFormat.png);
      if (data != null) File('${dir.path}/$name.png').writeAsBytesSync(data.buffer.asUint8List());
    }
    try {
      c.setMcuPin('1234');
      await c.powerOn();
      expect(c.running.value, false, reason: '12V power alone must not boot cluster');
      await c.longPressReady();
      expect(c.bootNeedsPassword, true);
      await until(() => c.vehicle.state == VehicleState.locked, seconds: 90);
      await Future<void>.delayed(const Duration(seconds: 1));
      await snap('01-password-page');
      expect(c.mcuPassword.active, true, reason: 'password session must be active');

      // Do NOT type the password. Firmware PasswordUL runs its own
      // 20s idle + 10s countdown and then emits bit5 (shutdown_notify);
      // the MCU grace (35s) is only a fallback and must not fire first.
      final mark = lines.length;
      await snap('02-idle-waiting');
      await until(() => lines.skip(mark).any((l) => l.contains('bits=0x20')), seconds: 45);
      expect(lines.skip(mark).any((l) => l.contains('固件 shutdown_notify')), true,
          reason: 'countdown end must arrive as firmware shutdown_notify (bit5)');
      expect(lines.skip(mark).any((l) => l.contains('密码页空闲超时')), false,
          reason: 'MCU fallback must not preempt the firmware countdown');
      await until(() => !c.running.value, seconds: 45);
      expect(c.vehicle.state, VehicleState.poweredOff,
          reason: 'idle password page must shut down after the firmware countdown');
      await Future<void>.delayed(const Duration(seconds: 1));
      await snap('03-shutdown');
    } finally {
      await c.stop();
      await logs.cancel();
      await out.close();
      await frames.cancel();
      frame?.dispose();
      c.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}

