// (prop, sub) 维度扫描：RX 分发可能按 (属性 id, 子索引) 选择处理器。
// guest 自己广播里同一属性出现过不同 sub（胎压 sub=1 / sub=4），说明 sub 是变体选择器。
// 本探针对候选属性 × sub 组合写入特征值，量 framebuffer 变化，看哪一组真正驱动画面。
//
//   AE5I_CFCP_TRACE=1 flutter test --no-pub test/sub_probe.dart
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

class Diff {
  Diff(this.top, this.mid, this.bot);
  final int top;
  final int mid;
  final int bot;
  @override
  String toString() => 'top=$top mid=$mid bot=$bot';
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
  return Diff(top, mid, bot);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('(prop,sub) sweep: which combination actually drives the cluster', () async {
    final controller = QemuController();
    ui.Image? latest;
    final frameSub = controller.frames.stream.listen((f) {
      latest?.dispose();
      latest = f;
    });
    final published = <String, int>{};
    final logSub = controller.log.stream.listen((l) {
      final m =
          RegExp(r'prop=0x([0-9a-f]+) sub=(\d+) value=(-?\d+)').firstMatch(l.text);
      if (m != null) {
        published['${m.group(1)}.${m.group(2)}'] = int.parse(m.group(3)!);
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
      stdout.writeln('guest 广播: ${published.keys.toList()}');

      // 候选属性：灯态/档位/状态/胎压/能力 + 几个上游相关
      const props = [
        0x21407072, // 灯态
        0x21407071, // 灯态相邻
        0x21407070,
        0x21709702, // 档位
        0x21709701,
        0x21709703,
        0x21707701, // 状态
        0x21707702,
        0x27407404, // 能力/胎压
        0x27400027,
        0x27410028,
      ];

      stdout.writeln('\n===== (prop, sub) 扫描，写入 0x5A5A =====');
      for (final p in props) {
        for (final sub in [0, 1, 2, 3, 4]) {
          final ref = (await grab())!;
          await controller.sendVehicleProp(p, sub: sub, intValue: 0x5a5a);
          await Future<void>.delayed(const Duration(milliseconds: 700));
          final cur = (await grab())!;
          final d = diffFrames(ref, cur, w, h);
          final echoed = published['${p.toRadixString(16)}.$sub'];
          final hit = (d.top + d.mid + d.bot) > 0;
          if (hit || echoed == 0x5a5a) {
            stdout.writeln('  prop=0x${p.toRadixString(16)} sub=$sub  $d'
                '${echoed == 0x5a5a ? '  [guest 回播=我发的值]' : ''}'
                '${hit ? '  ★★ 有画面变化' : ''}');
          }
        }
      }
      stdout.writeln('（未列出的组合＝画面 0 变化且 guest 未回播）');

      stdout.writeln('\n===== guest 最终广播汇总 =====');
      published.forEach((k, v) => stdout.writeln('  $k = $v'));
    } finally {
      await controller.stop();
      await frameSub.cancel();
      await logSub.cancel();
      latest?.dispose();
      controller.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 15)));
}
