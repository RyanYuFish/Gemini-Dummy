// 按键是否真的进入集群状态机：抓 guest 自己广播的属性帧，看按键前后
// 0x21407072（灯态）/0x21709702（档位）等的值是否变化。
//
// guest 侧广播是我们唯一的「集群真实状态」观测口（AE5I_CFCP_TRACE=1 打开）。
//
//   AE5I_CFCP_TRACE=1 flutter test --no-pub test/key_effect.dart
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
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
}

class Sample {
  Sample(this.prop, this.sub, this.value);
  final int prop;
  final int sub;
  final int value;
}

/// 从日志行里解析出 prop 帧：'CFCP ← prop=0x21407072 sub=0 value=30 (4B)'
Sample? parseProp(String line) {
  final m = RegExp(r'prop=0x([0-9a-f]+) sub=(\d+) value=(-?\d+)').firstMatch(line);
  if (m == null) return null;
  return Sample(int.parse(m.group(1)!, radix: 16),
      int.parse(m.group(2)!), int.parse(m.group(3)!));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('key effect: do key presses change the cluster published state?', () async {
    final controller = QemuController();
    final props = <int, List<Sample>>{};
    final logSub = controller.log.stream.listen((l) {
      final p = parseProp(l.text);
      if (p != null) {
        (props[p.prop] ??= []).add(p);
      }
    });

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
      final r = await controller.longPressReady();
      stdout.writeln('longPressReady accepted=${r.accepted}');
      await Future<void>.delayed(const Duration(seconds: 8));

      props.clear();
      stdout.writeln('\n===== 基线（按键前）=====');
      props.forEach((k, v) {
        if (v.isNotEmpty) {
          stdout.writeln('  0x${k.toRadixString(16)} : '
              '${v.map((e) => e.value).toList()}');
        }
      });

      Future<void> probe(InstrumentKey k) async {
        final before = <int, int>{};
        props.forEach((key, v) {
          if (v.isNotEmpty) before[key] = v.last.value;
        });
        final res = await controller.pressInstrumentKey(k);
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        final changed = <String>[];
        props.forEach((key, v) {
          if (v.isEmpty) return;
          final old = before[key];
          if (old != null && old != v.last.value) {
            changed.add('0x${key.toRadixString(16)}: $old -> ${v.last.value}');
          }
        });
        stdout.writeln('  ${k.label}(${k.sub}) -> ${res ?? 'null'}'
            '${changed.isEmpty ? '   [guest 广播无变化]' : '   * ${changed.join(", ")}'}');
      }

      stdout.writeln('\n===== MCU 车身键 =====');
      for (final k in kKeys) {
        if (k.mcu == null) continue;
        await probe(k);
      }
      stdout.writeln('\n===== 面板键 =====');
      for (final k in kKeys) {
        if (k.code == null) continue;
        await probe(k);
      }

      stdout.writeln('\n===== guest 广播属性全集 =====');
      props.forEach((k, v) {
        if (v.isEmpty) return;
        final vals = v.map((e) => e.value).toList();
        final show = vals.length > 14 ? '${vals.sublist(0, 14)}..(${vals.length})' : '$vals';
        stdout.writeln('  0x${k.toRadixString(16)} : $show');
      });
    } finally {
      await controller.stop();
      await logSub.cancel();
      controller.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 15)));
}
