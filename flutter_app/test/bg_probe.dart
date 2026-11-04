// 背景层取证：为什么 P 档右下那块背景（绿色墙 + 整车模型）不渲染。
//
// 参考实车照片 IMG_7663：P 档时左侧信息栏 + 右侧绿色背景墙 + 中央整车模型。
// 我们的截图右半屏全黑 ⇒ guest 没往背景层（窗口 1 / PFC background）画东西。
//
// 本探针：
//   1) 打开模型侧 fib 注册表转储（SP_FB_REG=1）与 PFC/背景相关日志；
//   2) 走到面板可达各页，逐页记录日志与 painted%；
//   3) 打印所有与 framebuffer / background / PFC / layer 相关的 guest 行。
//
//   flutter test --no-pub test/bg_probe.dart
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:ae5i_emu/emu/controller.dart';
import 'package:ae5i_emu/emu/vehicle.dart';
import 'package:ae5i_emu/emu/keys.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> waitUntil(bool Function() condition, Duration timeout) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) throw TimeoutException('condition not met');
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
}

int paintedNonBg(Uint8List a) {
  var n = 0;
  for (var i = 0; i + 2 < a.length; i += 4) {
    if (a[i] > 8 || a[i + 1] > 8 || a[i + 2] > 8) n++;
  }
  return n;
}

const _keys = [
  'Framebuffer',
  'Background',
  'background',
  'PFC',
  'pfc',
  'layer',
  'Layer',
  'registered_fb',
  'vendor fb',
  'dss',
  'DSS',
  'VPP',
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('background layer forensic: is the P-gear bg ever drawn?', () async {
    final controller = QemuController();
    ui.Image? latest;
    final frameSub = controller.frames.stream.listen((f) {
      latest?.dispose();
      latest = f;
    });
    final hits = <String>[];
    final logSub = controller.log.stream.listen((l) {
      final t = l.text;
      if (_keys.any(t.contains)) {
        if (hits.length < 400) hits.add(t);
      }
    });

    Future<Uint8List?> grab() async {
      final img = latest?.clone();
      if (img == null) return null;
      final d = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
      img.dispose();
      return d?.buffer.asUint8List();
    }

    final outDir = Directory(
      '${Directory.current.parent.parent.path}/dist/qemu-ae5i/bg',
    )..createSync(recursive: true);

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
      await Future<void>.delayed(const Duration(seconds: 6));

      Future<void> shot(String name) async {
        final d = (await grab())!;
        final img = latest!.clone();
        final png = await img.toByteData(format: ui.ImageByteFormat.png);
        img.dispose();
        File('${outDir.path}/$name.png')
            .writeAsBytesSync(png!.buffer.asUint8List());
        stdout.writeln('  shot $name  painted=${paintedNonBg(d)}');
      }

      stdout.writeln('=== 面板导航逐页 ===');
      await shot('A_ready');
      var i = 0;
      for (final k in kKeys) {
        if (k.code == null) continue;
        await controller.pressInstrumentKey(k);
        await Future<void>.delayed(const Duration(milliseconds: 900));
        // 用 label+序号做文件名：SET/BACK 的 sub 都是「中文 + 符号」，消毒后会撞名。
        final idx = (i++).toString().padLeft(2, '0');
        final safe = k.label.replaceAll(RegExp(r'[^A-Za-z0-9]'), '_');
        await shot('B${idx}_${safe}_0x${k.code!.toRadixString(16)}');
      }

      stdout.writeln('\n=== framebuffer / background / PFC 相关 guest 日志 ===');
      for (final h in hits) {
        stdout.writeln('  $h');
      }
      if (hits.isEmpty) {
        stdout.writeln('  （无匹配行 —— guest 可能从未创建背景 framebuffer）');
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
