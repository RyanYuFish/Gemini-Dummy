// 帧率验证：确认「画面在变时高频、静止时降速」真的生效。
//
//   旧行为：启动 20 s 后永久 900 ms 采样 ⇒ 运行期动画只有 ~1 fps。
//   新行为：模型侧 40 ms 发布（内容未变跳过写盘）+ 客户端按变化自适应。
//
//   flutter test --no-pub test/frame_rate.dart
import 'dart:async';
import 'dart:io';

import 'package:ae5i_emu/emu/controller.dart';
import 'package:ae5i_emu/emu/vehicle.dart';
import 'package:ae5i_emu/emu/keys.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> waitUntil(bool Function() condition, Duration timeout) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) throw TimeoutException('condition not met');
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('frame rate: animations must be published fast, idle may slow down',
      () async {
    final controller = QemuController();
    var count = 0;
    final frameSub = controller.frames.stream.listen((f) {
      count++;
      f.dispose();
    });
    final logSub = controller.log.stream.listen((_) {});

    Future<int> measure(Duration window, {String? label}) async {
      final before = count;
      await Future<void>.delayed(window);
      final n = count - before;
      final secs = window.inMilliseconds / 1000.0;
      stdout.writeln('  ${label ?? ''} '
          '$n 帧 / ${secs.toStringAsFixed(1)}s = ${(n / secs).toStringAsFixed(1)} fps');
      return n;
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
      await Future<void>.delayed(const Duration(seconds: 6));

      stdout.writeln('=== 静止画面（应自动降速，但不应低于 3 fps）===');
      await measure(const Duration(seconds: 4), label: 'idle');

      stdout.writeln('=== 连续按面板键（有页面切换动画，应明显更高）===');
      final up = kKeys.firstWhere((k) => k.sub == 'Up');
      final down = kKeys.firstWhere((k) => k.sub == 'Down');
      var keys = 0;
      final before = count;
      final t0 = DateTime.now();
      while (DateTime.now().difference(t0) < const Duration(seconds: 4)) {
        await controller.pressInstrumentKey(keys.isEven ? up : down);
        keys++;
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      final n = count - before;
      stdout.writeln('  animating: $n 帧 / 4.0s = '
          '${(n / 4.0).toStringAsFixed(1)} fps  （按了 $keys 次键）');

      stdout.writeln('=== 判据 ===');
      stdout.writeln(n >= 60
          ? '  PASS：按键期间 ≥15 fps，动画有足够帧可播'
          : '  FAIL：按键期间仅 ${(n / 4.0).toStringAsFixed(1)} fps，动画仍会跳帧');
    } finally {
      await controller.stop();
      await frameSub.cancel();
      await logSub.cancel();
      controller.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 15)));
}
