// 仪表页面勘察：以同一原厂 Launcher 页面比较客户端未 READY / READY 状态。
//
//   flutter test --no-pub test/cluster_pages_probe.dart
//
// 输出 PNG 与分区像素差、完整会话日志到 dist/qemu-ae5i/pages/。
// 客户端 READY 不等于 guest 接受了电机控制器数据，报告显式标记此证据边界。
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:ae5i_emu/emu/controller.dart';
import 'package:ae5i_emu/emu/vehicle.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> waitUntil(bool Function() condition, Duration timeout) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('condition not met');
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('probe: cluster pages and when the speed dial shows up', () async {
    final outDir = Directory(
      '${Directory.current.parent.parent.path}/dist/qemu-ae5i/pages',
    )..createSync(recursive: true);
    final controller = QemuController();
    ui.Image? latest;
    final frameSub = controller.frames.stream.listen((f) {
      latest?.dispose();
      latest = f;
    });
    final logs = <String>[];
    final logSub = controller.log.stream.listen((l) {
      logs.add('[${l.kind.name}] ${l.text}');
    });

    Future<Uint8List?> grab() async {
      final img = latest?.clone();
      if (img == null) return null;
      final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
      img.dispose();
      return data?.buffer.asUint8List();
    }

    final frames = <String, Uint8List>{};
    Future<void> shot(String name) async {
      final d = await grab();
      if (d == null) {
        stdout.writeln('!! $name: no frame');
        return;
      }
      final img = latest!.clone();
      final png = await img.toByteData(format: ui.ImageByteFormat.png);
      img.dispose();
      File(
        '${outDir.path}/$name.png',
      ).writeAsBytesSync(png!.buffer.asUint8List());
      frames[name] = d;
      stdout.writeln('shot: $name.png  state=${controller.vehicleState.value}');
    }

    Future<void> press(String label, int keyId) async {
      await controller.sendKeyEvent(label, keyId, true);
      await Future<void>.delayed(const Duration(milliseconds: 180));
      await controller.sendKeyEvent(label, keyId, false);
      await Future<void>.delayed(const Duration(milliseconds: 900));
    }

    try {
      await controller.powerOn();
      await waitUntil(
        () => controller.vehicleState.value == VehicleState.locked,
        const Duration(seconds: 170),
      );
      expect((await controller.swipeCard()).accepted, isTrue);
      // Wait for the animation to actually begin before waiting for its end;
      // checking only `!animating` races the wake-file notification and can
      // mistakenly capture the first boot-logo frame as a settled Launcher.
      await waitUntil(
        () => controller.animating.value,
        const Duration(seconds: 20),
      );
      await waitUntil(
        () => !controller.animating.value,
        const Duration(seconds: 90),
      );
      // The cluster module loads after the initial Launcher frame (about
      // guest 15 s). Compare vehicle states only after its MCUCOM connection,
      // otherwise both captures can precede the actual cluster consumer.
      await waitUntil(
        () => logs.any(
          (line) =>
              line.contains('dashclustor_getMCUComModule_init') &&
              line.contains('Connect true'),
        ),
        const Duration(seconds: 90),
      );
      await Future<void>.delayed(const Duration(seconds: 2));
      await shot('00-unlocked');

      // P-like parked client state and READY are captured on the same initial
      // Launcher page before navigation input can change the page/theme.
      // Client state is not evidence that the guest accepted vehicle status.
      controller.bleConnected.value = true;
      controller.tboxOnline.value = true;
      final ready = await controller.longPressReady();
      expect(ready.accepted, isTrue);
      expect(controller.vehicleState.value, VehicleState.ready);
      await Future<void>.delayed(const Duration(seconds: 2));
      await shot('10-ready-same-page');

      // READY 状态验证同一组原厂导航输入与 framebuffer 更新。
      await press('上', 0xd2);
      await shot('11-ready-up1');
      await press('上', 0xd2);
      await shot('12-ready-up2');
      await press('下', 0xd3);
      await shot('13-ready-down1');
      await press('SET', 0xd4);
      await shot('14-ready-set');
      await press('BACK', 0xd5);
      await shot('15-ready-back');

      final report = StringBuffer()
        ..writeln(
          'profile=AE5I guest; SPVD=${Platform.environment['AE5I_SPVD'] ?? '(default candidate)'}; framebuffer=1024x600 RGBA',
        )
        ..writeln('parked-like=client unlocked; guest P status unverified')
        ..writeln(
          'ready=client VehicleState.ready; guest READY status unverified',
        )
        ..writeln('real references: instruction/IMG_7663.jpeg, IMG_7664.jpeg')
        ..writeln('capture gate: animation ended; cluster MCUCOM Connect true')
        ..writeln(
          'frame region order: left(0..255), center(256..767), right(768..1023), footer(y>=500)',
        );
      final parked = frames['00-unlocked'];
      final readyFrame = frames['10-ready-same-page'];
      if (parked != null && readyFrame != null) {
        report.writeln(
          'same-page client state delta: ${pixelDiff(parked, readyFrame, 1024, 600)}',
        );
      }
      report.write('\n--- QEMU/client logs ---\n${logs.join('\n')}\n');
      File('${outDir.path}/states.txt').writeAsStringSync(report.toString());
    } finally {
      await controller.stop();
      await frameSub.cancel();
      await logSub.cancel();
      latest?.dispose();
      controller.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 8)));
}

String pixelDiff(Uint8List a, Uint8List b, int width, int height) {
  if (a.length != b.length || a.length != width * height * 4) {
    return 'invalid dimensions (${a.length} vs ${b.length})';
  }
  final count = List<int>.filled(4, 0);
  final boxes = List<List<int>>.generate(4, (_) => [width, height, -1, -1]);
  for (var p = 0; p < width * height; p++) {
    final i = p * 4;
    if (a[i] == b[i] && a[i + 1] == b[i + 1] && a[i + 2] == b[i + 2]) continue;
    final x = p % width, y = p ~/ width;
    final region = x < 256 ? 0 : (x < 768 ? 1 : 2);
    for (final r in [region, if (y >= 500) 3]) {
      count[r]++;
      final box = boxes[r];
      if (x < box[0]) box[0] = x;
      if (y < box[1]) box[1] = y;
      if (x > box[2]) box[2] = x;
      if (y > box[3]) box[3] = y;
    }
  }
  const names = ['left', 'center', 'right', 'footer'];
  return [
    for (var r = 0; r < 4; r++)
      '${names[r]}=${count[r]}px'
          '${count[r] == 0 ? '' : '@${boxes[r]}'}',
  ].join(' ');
}
