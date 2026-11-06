// Explicit real-QEMU acceptance probe. No client-side password input/state.
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
    if (DateTime.now().isAfter(end)) throw TimeoutException('native flow timeout');
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('real firmware password page and verification', () async {
    final c = QemuController();
    final dir = Directory('../dist/password-acceptance')..createSync(recursive: true);
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
      expect(c.vehicle.state, VehicleState.poweredOff);
      await c.longPressReady();
      expect(c.bootNeedsPassword, true);
      await until(() => c.vehicle.state == VehicleState.locked, seconds: 90);
      await Future<void>.delayed(const Duration(seconds: 3));
      await snap('01-password');
      expect(c.animating.value, false, reason: 'no logo before password verified');
      expect(c.mcuPassword.active, true);
      Future<void> tap(PasswordKey key) async {
        await c.pwKeyDown(key);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await c.pwKeyUp(key);
        await Future<void>.delayed(const Duration(milliseconds: 160));
      }
      // Wrong 0000 must stay locked; only native Qt checks input against 1234.
      for (var i = 0; i < 4; i++) { await tap(PasswordKey.set); }
      await Future<void>.delayed(const Duration(seconds: 3));
      expect(c.vehicle.state, VehicleState.locked);
      expect(c.mcuPassword.active, true);
      expect(c.animating.value, false);
      await snap('01b-wrong-password');
      // 原厂错误页要求 SET 重新输入；此键不会确认第一位数字。
      await tap(PasswordKey.set);
      for (var digit = 1; digit <= 4; digit++) {
        for (var n = 0; n < digit; n++) { await tap(PasswordKey.up); }
        await tap(PasswordKey.set);
      }
      await until(() => c.vehicle.state == VehicleState.unlocked, seconds: 30);
      await snap('02-verified');
      expect(lines.any((l) => l.contains('收到固件 PasswordUL')), true);
      await until(() => c.animating.value, seconds: 10);
      await snap('03-logo');
      await until(() => !c.animating.value, seconds: 20);
      await Future<void>.delayed(const Duration(seconds: 8));
      await snap('04-dashboard');
      // Normal lock must retain 12V. NFC can wake again without unplugging.
      await c.swipeCard();
      await until(() => !c.running.value, seconds: 30);
      expect(c.vehicle.state, VehicleState.poweredOff);
      expect(c.vehicle.state.isPowered, true);
      var mark = lines.length;
      await c.swipeCard();
      expect(c.bootNeedsPassword, false);
      await until(() => c.vehicle.state == VehicleState.unlocked, seconds: 60);
      await Future<void>.delayed(const Duration(seconds: 3));
      expect(lines.skip(mark).any((l) => l.contains('PasswordUL showEvent')), false);
      await snap('05-nfc');
      await c.requestPowerOff('验收 NFC 关机');
      await until(() => !c.running.value, seconds: 30);
      c.setBleConnected(true);
      mark = lines.length;
      await c.longPressReady();
      expect(c.bootNeedsPassword, false);
      await until(() => c.vehicle.state == VehicleState.unlocked, seconds: 60);
      await Future<void>.delayed(const Duration(seconds: 3));
      expect(lines.skip(mark).any((l) => l.contains('PasswordUL showEvent')), false);
      await snap('06-bluetooth-key');
      await c.requestPowerOff('验收蓝牙钥匙关机');
      await until(() => !c.running.value, seconds: 30);
      c.setBleConnected(false);
      await c.longPressReady();
      await until(() => c.vehicle.state == VehicleState.locked, seconds: 60);
      await Future<void>.delayed(const Duration(seconds: 2));
      mark = lines.length;
      await c.pwKeyDown(PasswordKey.back);
      await Future<void>.delayed(const Duration(milliseconds: 3500));
      await c.pwKeyUp(PasswordKey.back);
      await until(() => !c.running.value, seconds: 30);
      expect(c.vehicle.state, VehicleState.poweredOff);
      expect(lines.skip(mark).any((l) => l.contains('bits=0x20')), true,
          reason: 'guest native PasswordUL must emit shutdown bit5');
      final unplug = await c.unplugPower();
      expect(unplug.accepted, true);
      expect(c.vehicle.state, VehicleState.off);
    } finally {
      await c.stop();
      await logs.cancel(); await out.close();
      await frames.cancel(); frame?.dispose(); c.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
