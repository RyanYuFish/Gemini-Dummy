// 上行取证探针：抓 guest（内核 CFCP 驱动）→ 客户端方向的全部帧。
//
// 目的：EMULATION.md §23.4 记录「MCU→SoC 的车辆信号帧未实现：没有 GD32 peer 应答属性读」。
// 本探针打开 AE5I_CFCP_TRACE，把 guest 实际发来的帧原样打印出来，
// 以便确定「属性读请求」的帧格式，从而实现应答侧。
//
//   AE5I_CFCP_TRACE=1 flutter test --no-pub test/cfcp_upstream.dart
import 'dart:async';
import 'dart:io';

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('upstream capture: what does the guest ask us for?', () async {
    final controller = QemuController();
    final rx = <String>[];
    final logSub = controller.log.stream.listen((l) {
      final t = l.text;
      if (t.contains('CFCP ←')) rx.add(t);
    });

    try {
      await controller.powerOn();
      await waitUntil(
        () => controller.vehicleState.value == VehicleState.locked,
        const Duration(seconds: 170),
      );
      expect((await controller.swipeCard()).accepted, isTrue);
      // 开机动画可能不触发 animating 标志，这里不阻塞等待，只留出时间让 guest 起来。
      await Future<void>.delayed(const Duration(seconds: 20));
      controller.bleConnected.value = true;
      controller.tboxOnline.value = true;
      // 解锁 → 触发 GD32 基线上报 + guest 侧开始取车辆数据
      final r = await controller.longPressReady();
      stdout.writeln('longPressReady accepted=${r.accepted} '
          'state=${controller.vehicleState.value}');
      await Future<void>.delayed(const Duration(seconds: 15));

      stdout.writeln('\n########## guest → client 帧（去重聚合）##########');
      final byKey = <String, int>{};
      final order = <String>[];
      for (final t in rx) {
        // 取 type/cmd 与长度做 key
        final m = RegExp(r'type=0x([0-9a-f]+) cmd=0x([0-9a-f]+)').firstMatch(t);
        final key = m == null ? t.substring(0, t.length < 60 ? t.length : 60)
            : 'type=0x${m.group(1)} cmd=0x${m.group(2)}';
        if (!byKey.containsKey(key)) order.add(key);
        byKey[key] = (byKey[key] ?? 0) + 1;
      }
      for (final k in order) {
        stdout.writeln('  $k   x${byKey[k]}');
      }
      stdout.writeln('\n########## 原始帧（前 40 条）##########');
      var i = 0;
      for (final t in rx) {
        if (i++ >= 40) break;
        stdout.writeln('  $t');
      }
      stdout.writeln('\n########## 非 ACK 的完整帧 ##########');
      i = 0;
      for (final t in rx) {
        if (t.contains('(ACK)')) continue;
        if (i++ >= 40) break;
        stdout.writeln('  $t');
      }
    } finally {
      await controller.stop();
      await logSub.cancel();
      controller.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 12)));
}
