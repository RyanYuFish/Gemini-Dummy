// 灯态位图解码 + 上行生效验证：
//   1) 逐个候选值写 0x21407072，量 framebuffer 顶部指示灯区变化 → 反推 bit→灯 映射；
//   2) 同时看 guest 是否把我们的值回播出来（证明帧进了集群属性表）。
//
//   AE5I_CFCP_TRACE=1 flutter test --no-pub test/lamp_bits.dart
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
    if (DateTime.now().isAfter(deadline)) throw TimeoutException('condition not met');
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
}

/// 分区差异：顶部指示灯带 / 中部 / 其余
class Diff {
  Diff(this.top, this.mid, this.bot, this.total);
  final int top;
  final int mid;
  final int bot;
  final int total;
  @override
  String toString() => 'top=$top mid=$mid bot=$bot total=$total';
}

Diff diffFrames(Uint8List a, Uint8List b, int w, int h) {
  var top = 0, mid = 0, bot = 0;
  for (var p = 0; p < w * h; p++) {
    final i = p * 4;
    if (a[i] == b[i] && a[i + 1] == b[i + 1] && a[i + 2] == b[i + 2]) continue;
    final y = p ~/ w;
    if (y < 80) {
      top++;
    } else if (y < 500) {
      mid++;
    } else {
      bot++;
    }
  }
  return Diff(top, mid, bot, top + mid + bot);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('lamp bitmask: decode 0x21407072 by observing the indicator strip',
      () async {
    final controller = QemuController();
    ui.Image? latest;
    final frameSub = controller.frames.stream.listen((f) {
      latest?.dispose();
      latest = f;
    });
    final published = <int, int>{};
    final logSub = controller.log.stream.listen((l) {
      final m = RegExp(r'prop=0x([0-9a-f]+) sub=\d+ value=(-?\d+)').firstMatch(l.text);
      if (m != null) {
        published[int.parse(m.group(1)!, radix: 16)] = int.parse(m.group(2)!);
      }
    });

    Future<Uint8List?> grab() async {
      final img = latest?.clone();
      if (img == null) return null;
      final d = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
      img.dispose();
      return d?.buffer.asUint8List();
    }

    try {
      await controller.powerOn();
      await waitUntil(
        () => controller.vehicleState.value == VehicleState.locked,
        const Duration(seconds: 170),
      );
      expect((await controller.swipeCard()).accepted, isTrue);
      await Future<void>.delayed(const Duration(seconds: 20));
      controller.bleConnected.value = true;
      controller.tboxOnline.value = true;
      expect((await controller.longPressReady()).accepted, isTrue);
      await Future<void>.delayed(const Duration(seconds: 8));

      final w = latest!.width, h = latest!.height;
      stdout.writeln('frame ${w}x$h');

      // 基线值取 guest 自己广播的那个（通常是「全灭」附近的常驻位）
      const lampProp = 0x21407072;
      final base = published[lampProp] ?? 0;
      stdout.writeln('guest 基线灯态 = $base (0x${base.toRadixString(16)})');

      Future<void> tryValue(int v) async {
        // 先回到基线，再切到候选值，量差异
        await controller.sendVehicleProp(lampProp, intValue: base);
        await Future<void>.delayed(const Duration(milliseconds: 800));
        final ref = (await grab())!;
        await controller.sendVehicleProp(lampProp, intValue: v);
        await Future<void>.delayed(const Duration(milliseconds: 800));
        final cur = (await grab())!;
        final d = diffFrames(ref, cur, w, h);
        final echo = published[lampProp];
        stdout.writeln('  lamp=$v (0x${v.toRadixString(16)})  $d'
            '${echo == v ? '   [guest 回播=我发的值 ✓ 帧已进属性表]' : '   [guest 回播=$echo]'}');
      }

      stdout.writeln('\n===== 候选灯态值 =====');
      for (final v in [
        base,
        0, 1, 2, 4, 8, 16, 32, 64, 128,
        3, 6, 12, 24, 48,
        0x03, 0x0c, 0x18, 0x16,
        30, 38, 13, 19, 42, 78,
      ]) {
        if (v == base) continue;
        await tryValue(v);
      }

      stdout.writeln('\n===== 档位 0x21709702（2 字节）=====');
      await controller.sendVehicleProp(lampProp, intValue: base);
      await Future<void>.delayed(const Duration(milliseconds: 800));
      final gref = (await grab())!;
      for (final g in [8, 9, 10]) {
        await controller.sendVehicleProp(0x21709702, rawValue: [g, 0]);
        await Future<void>.delayed(const Duration(milliseconds: 900));
        final gcur = (await grab())!;
        stdout.writeln('  gear=$g  ${diffFrames(gref, gcur, w, h)}');
      }
    } finally {
      await controller.stop();
      await frameSub.cancel();
      await logSub.cancel();
      latest?.dispose();
      controller.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 15)));
}
