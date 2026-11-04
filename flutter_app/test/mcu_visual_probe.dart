// 属性 id 校准探针：把候选 CFCP 属性帧打进真机固件，逐张比对 framebuffer。
//
//   flutter test --no-pub test/mcu_visual_probe.dart
//
// 输出 PNG 到 /tmp/mcuvis/，命名体现「打了哪一帧」，用于人工/像素比对
// 判定 prop id 与取值到底有没有改变仪表画面（例如档位数字、指示灯）。
import 'dart:async';
import 'dart:io';
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
  test(
    'probe: which CFCP prop actually changes the cluster',
    () async {
      final outDir = Directory('/tmp/mcuvis')..createSync(recursive: true);
      final controller = QemuController();
      ui.Image? latest;
      final sub = controller.frames.stream.listen((f) {
        latest?.dispose();
        latest = f;
      });
      final logSub = controller.log.stream.listen((l) {
        if (l.text.contains('GD32') || l.text.contains('CFCP ←')) {
          // 只留关键行，避免刷屏
        }
      });

      Future<void> shot(String name) async {
        await Future<void>.delayed(const Duration(milliseconds: 1200));
        final img = latest?.clone();
        if (img == null) {
          stdout.writeln('!! $name: no frame');
          return;
        }
        final data = await img.toByteData(format: ui.ImageByteFormat.png);
        img.dispose();
        if (data == null) return;
        File('${outDir.path}/$name.png')
            .writeAsBytesSync(data.buffer.asUint8List());
        stdout.writeln('shot: $name.png');
      }

      try {
        await controller.powerOn();
        await waitUntil(
          () => controller.vehicleState.value == VehicleState.locked,
          const Duration(seconds: 170),
        );
        expect((await controller.swipeCard()).accepted, isTrue);
        await waitUntil(
          () => controller.animating.value,
          const Duration(seconds: 20),
        );
        await waitUntil(
          () => !controller.animating.value,
          const Duration(seconds: 60),
        );
        await shot('00-baseline');

        // 候选 1：0x21709702，2 字节值 8/9/10（本会话里 guest 自己发过的档位候选）
        for (final v in [8, 9, 10]) {
          await controller.sendVehicleProp(0x21709702,
              rawValue: [v & 0xff, 0x00]);
          await shot('10-prop21709702-val$v');
        }

        // 候选 2：0x21407072，int32 值（抓包里 guest 自己发过 -23/27/30）
        for (final v in [0, 0x1e, 0x1b]) {
          await controller.sendVehicleProp(0x21407072, intValue: v);
          await shot('20-prop21407072-val$v');
        }

        // 候选 3：老代码用的 0x21977002（怀疑是 0x21709702 的笔误），作对照
        await controller.sendVehicleProp(0x21977002, intValue: 10);
        await shot('30-prop21977002-val10');
      } finally {
        await controller.stop();
        await sub.cancel();
        await logSub.cancel();
        latest?.dispose();
        controller.dispose();
      }
    },
    timeout: const Timeout(Duration(minutes: 6)),
  );
}
