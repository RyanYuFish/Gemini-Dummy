// 动画渲染质量对比：开机 logo 动画期间的真实到达帧率与帧间隔。
//
//   默认走原始 BGRA 通道（模型直出 + .meta，客户端零转换）
//   AE5I_FORCE_PPM=1 走旧 PPM 通道（每帧 2×61 万次 Dart 循环）
//
// 判据不是"帧越多越好"（静止画面本来就该 0 帧），而是**动画窗口内**
// 能否达到接近原厂 60 fps 的一半以上，以及帧间隔是否稳定。
//
//   flutter test --no-pub test/anim_quality.dart
import 'dart:async';
import 'dart:io';

import 'package:ae5i_emu/emu/controller.dart';
import 'package:ae5i_emu/emu/vehicle.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> waitUntil(bool Function() condition, Duration timeout) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('condition not met');
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('animation frame quality (raw bgra vs ppm)', () async {
    final controller = QemuController();
    final stamps = <DateTime>[];
    final frameSub = controller.frames.stream.listen((f) {
      stamps.add(DateTime.now());
      f.dispose();
    });
    final logSub = controller.log.stream.listen((_) {});

    try {
      await controller.powerOn();
      await waitUntil(
        () => controller.vehicleState.value == VehicleState.locked,
        const Duration(seconds: 170),
      );
      stdout.writeln('=== 已到 locked，开始刷卡解锁（触发开机动画重放）===');
      stamps.clear();
      final t0 = DateTime.now();
      expect((await controller.swipeCard()).accepted, isTrue);
      // 原厂 logo 约 1.9 s 播完；留 6 s 窗口覆盖动画 + 首帧 Launcher
      await Future<void>.delayed(const Duration(seconds: 6));
      final n = stamps.length;
      stdout.writeln('  动画窗口内到达 $n 帧 / 6.0s = '
          '${(n / 6.0).toStringAsFixed(1)} fps');
      // 时间线：空档出现在动画之前还是之后，直接决定结论。
      final tl = stamps.map((s) => s.difference(t0).inMilliseconds).toList();
      stdout.writeln('  时间线(ms): ${tl.take(30).join(",")}'
          '${tl.length > 30 ? " ... 末 ${tl.last}" : ""}');

      if (stamps.length >= 3) {
        final gaps = <int>[];
        for (var i = 1; i < stamps.length; i++) {
          gaps.add(stamps[i].difference(stamps[i - 1]).inMilliseconds);
        }
        gaps.sort();
        final p50 = gaps[gaps.length ~/ 2];
        final p95 = gaps[(gaps.length * 95) ~/ 100];
        final firstAt = stamps.first.difference(t0).inMilliseconds;
        stdout.writeln('  帧间隔 p50=${p50}ms p95=${p95}ms '
            'min=${gaps.first}ms max=${gaps.last}ms');
        stdout.writeln('  首帧延迟 ${firstAt}ms');
      }
      stdout.writeln('  painted=${controller.displayPaintedPct.value.toStringAsFixed(4)} '
          'frameErrors=${controller.frameErrors}');
    } finally {
      await controller.stop();
      await frameSub.cancel();
      await logSub.cancel();
      controller.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 12)));
}
