// CFCP 属性 id 扫描器：把候选属性帧逐条打进真机固件，用 framebuffer 像素差做判据。
//
//   flutter test --no-pub test/mcu_prop_scan.dart
//
// 判据设计（重要，避免自欺）：
//   1. 先连拍两次基线，量出「同一状态下的帧间噪声」noiseFloor；
//   2. 每个候选属性只改一个变量（prop id / 值），其余保持不动；
//   3. 变化像素数必须显著高于 noiseFloor 才算「有效果」，并打印变化区域的包围盒，
//      便于判断是主表盘、档位、指示灯还是时钟。
//
// 候选集来源：`libvehiclesignalmodule.so` 里 `updateIntVehiclePropValue` 的
// **switch 跳转表实解**（见 EMULATION.md §27），不是猜的。
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

/// 像素差结果：变化点数 + 包围盒。
class FrameDiff {
  FrameDiff(this.count, this.x0, this.y0, this.x1, this.y1);
  final int count;
  final int x0, y0, x1, y1;
  bool get empty => count == 0;
  @override
  String toString() => empty
      ? '0 px'
      : '$count px  bbox=($x0,$y0)-($x1,$y1)';
}

FrameDiff diff(Uint8List a, Uint8List b, int w) {
  var n = 0, x0 = 1 << 30, y0 = 1 << 30, x1 = -1, y1 = -1;
  for (var i = 0; i + 3 < a.length && i + 3 < b.length; i += 4) {
    if (a[i] != b[i] || a[i + 1] != b[i + 1] || a[i + 2] != b[i + 2]) {
      n++;
      final p = i >> 2;
      final x = p % w, y = p ~/ w;
      if (x < x0) x0 = x;
      if (x > x1) x1 = x;
      if (y < y0) y0 = y;
      if (y > y1) y1 = y;
    }
  }
  return FrameDiff(n, x0, y0, x1, y1);
}

/// 候选：属性 id + 试打的值列表。分组注释写清来源。
const candidates = <({int prop, List<int> values, String why})>[
  // ---- A. updateIntVehiclePropValue 的 switch 实解（这些是固件真的会处理的 id）----
  (prop: 0x21400002, values: [0, 1, 60], why: 'int-switch segA live'),
  (prop: 0x21400003, values: [0, 1, 60], why: 'int-switch segA live'),
  (prop: 0x21400004, values: [0, 1, 60], why: 'int-switch segA live'),
  (prop: 0x21400006, values: [0, 1, 60], why: 'int-switch segA live'),
  (prop: 0x21400009, values: [0, 1, 60], why: 'int-switch segA live'),
  (prop: 0x21400031, values: [0, 1, 60], why: 'int-switch explicit'),
  (prop: 0x21400032, values: [0, 1, 60], why: 'int-switch explicit'),
  (prop: 0x2140100D, values: [0, 1, 60], why: 'int-switch explicit'),
  (prop: 0x21407059, values: [0, 1, 60], why: 'int-switch segB live'),
  (prop: 0x21407060, values: [0, 1, 60], why: 'int-switch segB live'),
  (prop: 0x21407061, values: [0, 1, 60], why: 'int-switch segB live'),
  (prop: 0x21407062, values: [0, 1, 60], why: 'int-switch segB live'),
  (prop: 0x21407063, values: [0, 1, 60], why: 'int-switch segB live'),
  (prop: 0x21407064, values: [0, 1, 60], why: 'int-switch segB live'),
  (prop: 0x21407148, values: [0, 1, 60], why: 'int-switch explicit'),
  (prop: 0x21407403, values: [0, 1, 60], why: 'int-switch explicit'),
  (prop: 0x27400027, values: [0, 1, 60], why: 'int-switch explicit'),
  (prop: 0x27407404, values: [0, 1, 60], why: 'int-switch explicit'),
  // ---- B. updateBytesVehiclePropValue 的 2 个 id ----
  (prop: 0x21701003, values: [0, 1], why: 'bytes-switch'),
  (prop: 0x21701005, values: [0, 1], why: 'bytes-switch'),
  // ---- C. 真机抓包里 SoC 自己往 MCU 方向发过的 id（待判真假）----
  (prop: 0x21407072, values: [0, 3, 0x18], why: 'capture: lamp status?'),
  (prop: 0x21709702, values: [0, 8, 10], why: 'capture: 2B value 8/9/10'),
  (prop: 0x21707701, values: [0, 0xc0], why: 'capture: status byte'),
  // ---- D. 已证实的基线帧，作为「链路活着」的对照 ----
  (prop: 0x21417310, values: [1], why: 'proven handshake'),
  (prop: 0x21709521, values: [0], why: 'proven heartbeat'),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'scan: which CFCP prop actually repaints the cluster',
    () async {
      final outDir = Directory(
        '${Directory.current.parent.parent.path}/dist/qemu-ae5i',
      )..createSync(recursive: true);
      final report = StringBuffer();
      void say(String s) {
        stdout.writeln(s);
        report.writeln(s);
      }

      final controller = QemuController();
      ui.Image? latest;
      final frameSub = controller.frames.stream.listen((f) {
        latest?.dispose();
        latest = f;
      });
      final cfcpLines = <String>[];
      final logSub = controller.log.stream.listen((l) {
        if (l.text.contains('CFCP') || l.text.contains('GD32')) {
          cfcpLines.add(l.text);
        }
      });

      Future<Uint8List?> grab() async {
        final img = latest?.clone();
        if (img == null) return null;
        final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
        img.dispose();
        return data?.buffer.asUint8List();
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
        // 让 Launcher 稳定一会儿再取基线。
        await Future<void>.delayed(const Duration(seconds: 3));

        final base = await grab();
        expect(base, isNotNull, reason: 'framebuffer 必须有内容');
        final w = latest!.width;
        say('base frame: ${latest!.width}x${latest!.height}');

        // 噪声地板：基线到基线。
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        final base2 = await grab();
        final noise = diff(base!, base2!, w);
        say('noiseFloor (baseline→baseline, 1.5s): $noise');
        say('');

        final rows = <String>[];
        for (final c in candidates) {
          for (final v in c.values) {
            final before = await grab();
            await controller.sendVehicleProp(
              c.prop,
              intValue: v,
              log: false,
            );
            await Future<void>.delayed(const Duration(milliseconds: 1200));
            final after = await grab();
            final d = diff(before!, after!, w);
            final tag = d.empty
                ? '   -   '
                : (d.count > noise.count * 3 ? ' HIT!  ' : ' noise?');
            final row =
                '$tag prop=0x${c.prop.toRadixString(16).padLeft(8, '0')} '
                'val=${v.toString().padLeft(4)}  ${d.toString().padRight(34)}'
                '  [${c.why}]';
            rows.add(row);
            say(row);
          }
        }

        say('');
        say('=== 汇总：只有标记 HIT! 的才是真的驱动了画面 ===');
        for (final r in rows.where((r) => r.startsWith(' HIT!'))) {
          say(r);
        }
        say('');
        say('cfcp/log 行数：${cfcpLines.length}');
        for (final l in cfcpLines.take(20)) {
          say('  $l');
        }
        File('${outDir.path}/prop-scan.txt').writeAsStringSync(report.toString());
      } finally {
        await controller.stop();
        await frameSub.cancel();
        await logSub.cancel();
        latest?.dispose();
        controller.dispose();
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
