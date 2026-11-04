// MCU 仿真端到端探针 v2：
//   1) 修掉上一版文件名里有 '/' 与空格导致崩溃的 bug（SET 键 sub='确认 / ►'）。
//   2) 面板键导航：把每个可达页面截图存盘，便于肉眼确认"主表盘"到底在哪个页面。
//   3) 把真机 libmcucommodule.so 里反汇编出的 60 个真实属性 id 一次性灌进去
//      （"车辆已激活"姿态），看主表盘/速度/档位是否出现。
//   4) 重新确认：校正后的 gear/lamp 属性帧在 ready 态是否驱动重绘。
//
//   flutter test --no-pub test/mcu_render_probe.dart
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

class RegionDiff {
  RegionDiff(this.counts);
  final List<int> counts;
  bool get empty => counts.every((c) => c == 0);
  @override
  String toString() => 'L=${counts[0]} C=${counts[1]} R=${counts[2]} F=${counts[3]}';
}

RegionDiff regionDiff(Uint8List a, Uint8List b, int w, int h) {
  final counts = [0, 0, 0, 0];
  for (var p = 0; p < w * h; p++) {
    final i = p * 4;
    if (a[i] == b[i] && a[i + 1] == b[i + 1] && a[i + 2] == b[i + 2]) continue;
    final x = p % w, y = p ~/ w;
    final region = x < 256 ? 0 : (x < 768 ? 1 : 2);
    counts[region]++;
    if (y >= 500) counts[3]++;
  }
  return RegionDiff(counts);
}

int paintedNonBg(Uint8List a, int w, int h) {
  var n = 0;
  for (var i = 0; i + 2 < a.length; i += 4) {
    if (a[i] > 8 || a[i + 1] > 8 || a[i + 2] > 8) n++;
  }
  return n;
}

/// 真机 libmcucommodule.so 反汇编出的全部 60 个真实属性 id（0x21/0x27 家族）。
const List<int> kAllRealProps = [
  0x21400004, 0x21400008, 0x21400030, 0x2140003b, 0x21402200,
  0x21407065, 0x21407066, 0x21407067, 0x21407068, 0x21407069,
  0x21407070, 0x21407071, 0x21407072, 0x21407191, 0x21407902,
  0x21409305, 0x21409308, 0x21409309, 0x21409505, 0x21409508, 0x2140b909,
  0x21700003, 0x217005eb, 0x21701002, 0x21701003, 0x21703953,
  0x21707073, 0x21707192, 0x21707701, 0x21707702, 0x21707703, 0x21707fff,
  0x21709301, 0x21709302, 0x21709303, 0x21709501, 0x21709502, 0x21709503, 0x21709504,
  0x21709510, 0x21709511, 0x21709513, 0x21709520, 0x21709521, 0x2170960b,
  0x21709700, 0x21709701, 0x21709702, 0x21709703,
  0x21709801, 0x21709802, 0x21709803, 0x2170b909, 0x2170c4f2, 0x2171b909,
  0x27400001, 0x27400027, 0x27407404, 0x2740d1f8, 0x2740f8df,
];

/// 对"车辆已激活"而言语义明确的属性 → 取值。
int burstValue(int prop) {
  switch (prop) {
    case 0x21417310: // 握手/就绪
      return 1;
    case 0x21701002: // 版本串（单独发 str）
    case 0x21701003:
      return -1; // 哨兵：用字符串发
    case 0x21709521: // 心跳
      return 0;
    case 0x27407404: // 能力掩码
      return 0xffffffff;
    case 0x21707701: // 车辆状态字节
    case 0x21707702:
    case 0x21707703:
      return 0xc0;
    case 0x21407072: // 灯态（灭）
      return 0;
    case 0x21709702: // 档位（2 字节；P?，先发 8）
      return -2; // 哨兵：用 raw [8,0]
    // 候选速度/里程类：给一个明显非零值看是否点亮速度盘
    case 0x21709510:
    case 0x21709511:
    case 0x21709513:
    case 0x2170960b:
    case 0x21709801:
    case 0x21709802:
    case 0x21709803:
      return 30;
    default:
      return 1; // 其余给"激活"信号 1
  }
}

String san(String s) => s.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('render+key probe v2: map pages + fire full property burst', () async {
    final outDir = Directory(
      '${Directory.current.parent.parent.path}/dist/qemu-ae5i/render',
    )..createSync(recursive: true);
    final controller = QemuController();
    ui.Image? latest;
    final frameSub = controller.frames.stream.listen((f) {
      latest?.dispose();
      latest = f;
    });
    final logLines = <String>[];
    final logSub = controller.log.stream.listen(
      (l) => logLines.add('[${l.kind.name}] ${l.text}'),
    );

    Future<Uint8List?> grab() async {
      final img = latest?.clone();
      if (img == null) return null;
      final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
      img.dispose();
      return data?.buffer.asUint8List();
    }

    final report = StringBuffer();
    void say(String s) {
      stdout.writeln(s);
      report.writeln(s);
    }

    try {
      await controller.powerOn();
      await waitUntil(
        () => controller.vehicleState.value == VehicleState.locked,
        const Duration(seconds: 170),
      );
      expect((await controller.swipeCard()).accepted, isTrue);
      await waitUntil(() => controller.animating.value, const Duration(seconds: 20));
      await waitUntil(() => !controller.animating.value, const Duration(seconds: 90));
      await waitUntil(
        () => logLines.any(
          (l) => l.contains('dashclustor_getMCUComModule_init') && l.contains('Connect true'),
        ),
        const Duration(seconds: 90),
      );
      await Future<void>.delayed(const Duration(seconds: 2));
      controller.bleConnected.value = true;
      controller.tboxOnline.value = true;
      final ready = await controller.longPressReady();
      expect(ready.accepted, isTrue);
      expect(controller.vehicleState.value, VehicleState.ready);
      await Future<void>.delayed(const Duration(seconds: 2));

      final base = (await grab())!;
      final w = latest!.width, h = latest!.height;
      say('base frame: ${w}x$h  painted~${paintedNonBg(base, w, h)}px');
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      final base2 = (await grab())!;
      final noise = regionDiff(base, base2, w, h);
      say('noiseFloor (1.5s): $noise');

      Future<String> shot(String name) async {
        final d = (await grab())!;
        final img = latest!.clone();
        final png = await img.toByteData(format: ui.ImageByteFormat.png);
        img.dispose();
        final fname = san(name);
        File('${outDir.path}/$fname.png').writeAsBytesSync(png!.buffer.asUint8List());
        final p = paintedNonBg(d, w, h);
        say('  shot $fname.png  painted~$p px');
        return fname;
      }

      // ---------- Page Map ----------
      say('');
      say('=== PAGE MAP：面板键导航（每步截图）===');
      await shot('00_ready');
      // 上/下纵向菜单：各按 6 次
      for (var i = 1; i <= 6; i++) {
        await controller.pressInstrumentKey(
          kKeys.firstWhere((k) => k.sub == 'Up'),
        );
        await Future<void>.delayed(const Duration(milliseconds: 700));
        await shot('01_up_$i');
      }
      for (var i = 1; i <= 6; i++) {
        await controller.pressInstrumentKey(
          kKeys.firstWhere((k) => k.sub == 'Down'),
        );
        await Future<void>.delayed(const Duration(milliseconds: 700));
        await shot('02_down_$i');
      }
      // SET(右) 钻入 / BACK(左) 返回：各 4 次
      for (var i = 1; i <= 4; i++) {
        await controller.pressInstrumentKey(
          kKeys.firstWhere((k) => k.sub == '确认 / ►'),
        );
        await Future<void>.delayed(const Duration(milliseconds: 700));
        await shot('03_set_$i');
      }
      for (var i = 1; i <= 4; i++) {
        await controller.pressInstrumentKey(
          kKeys.firstWhere((k) => k.sub == '返回 / ◄'),
        );
        await Future<void>.delayed(const Duration(milliseconds: 700));
        await shot('04_back_$i');
      }

      // ---------- Full property burst ----------
      say('');
      say('=== 全属性灌入（车辆已激活姿态）===');
      final beforeBurst = await grab();
      var sent = 0;
      for (final p in kAllRealProps) {
        final v = burstValue(p);
        if (v == -1) {
          // 版本串类（0x21701002/03）：sendVehicleProp 只支持 int/raw，跳过，
          // 它不驱动主表盘，不影响本探针结论。
          continue;
        } else if (v == -2) {
          await controller.sendVehicleProp(p, rawValue: [8, 0]);
        } else {
          await controller.sendVehicleProp(p, intValue: v);
        }
        sent++;
      }
      say('burst sent: $sent property frames');
      await Future<void>.delayed(const Duration(seconds: 3));
      final afterBurst = await grab();
      final d = regionDiff(beforeBurst!, afterBurst!, w, h);
      final tot = d.counts[0] + d.counts[1] + d.counts[2] + d.counts[3];
      final hit = tot > noise.counts.reduce((a, b) => a + b) * 3;
      say('burst vs before: $d  ${hit ? "HIT" : (d.empty ? "---" : "~noise")}');
      await shot('05_burst');

      // ---------- 重新确认 gear/lamp 单帧 ----------
      say('');
      say('=== 单帧确认：gear 0x21709702 / lamp 0x21407072 ===');
      for (final v in [8, 10, 9]) {
        final b = await grab();
        await controller.sendVehicleProp(0x21709702, rawValue: [v, 0]);
        await Future<void>.delayed(const Duration(milliseconds: 900));
        final a = await grab();
        final dd = regionDiff(b!, a!, w, h);
        say('gear raw=$v -> $dd');
      }
      for (final v in [0x03, 0x0c, 0x18, 0x16]) {
        final b = await grab();
        await controller.sendVehicleProp(0x21407072, intValue: v);
        await Future<void>.delayed(const Duration(milliseconds: 900));
        final a = await grab();
        final dd = regionDiff(b!, a!, w, h);
        say('lamp int=0x${v.toRadixString(16)} -> $dd');
      }

      say('');
      say('=== 关键日志（CFCP/MCU）===');
      for (final l in logLines.where((l) => l.contains('CFCP') || l.contains('GD32') || l.contains('MCU'))) {
        say('  $l');
      }
      File('${outDir.path}/render.txt').writeAsStringSync(report.toString());
      say('done; screenshots in ${outDir.path}');
    } finally {
      await controller.stop();
      await frameSub.cancel();
      await logSub.cancel();
      latest?.dispose();
      controller.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 15)));
}
