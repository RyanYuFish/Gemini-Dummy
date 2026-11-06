// Real-QEMU acceptance probe for the password-page auto-shutdown countdown.
//
// Verifies §50.2 end-to-end against live firmware:
//   password page opens (requirePassword) → no password is typed
//   → after the idle grace window the MCU emulator drives the auto-shutdown
//     (same path as long-press BACK / password timeout) → instrument powers off.
// This build's firmware does NOT honor MUCI_SIGNAL_AUTOMATIC_SHUTDOWN, so the
// MCU must run the countdown itself; this probe proves the idle page actually
// shuts the cluster down without any user input.
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:ae5i_emu/emu/controller.dart';
import 'package:ae5i_emu/emu/password.dart';
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

      // Do NOT type the password. The MCU emulator must auto-shut-down the
      // idle page after its grace window (default 20s) via _shutdownFromPassword.
      final mark = lines.length;
      await snap('02-idle-waiting');
      await until(() => !c.running.value, seconds: 45);
      expect(c.vehicle.state, VehicleState.poweredOff,
          reason: 'idle password page must auto-shut-down after grace window');
      expect(lines.skip(mark).any((l) => l.contains('密码页空闲超时')), true,
          reason: 'MCU must drive the idle auto-shutdown itself (firmware ignores signal)');
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

