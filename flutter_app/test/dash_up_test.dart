// 回归：MCU 对端三段式进场 + 帧字节与 tools/dash_up.py 一致。
//
// 这两条是 EMULATION.md §41 踩坑踩出来的红线，改任何一个都必然让画面退回
// 黑屏 / 待机统计页或产生整车拖尾、双图标：
//   1. 帧字节必须与原版 dash_up.py 逐字节一致；
//   2. pre-arm 不喂解锁、settle gear=0、enter 只写一次 gear=1。

import 'dart:typed_data';

import 'package:ae5i_emu/emu/dash_up.dart';
import 'package:flutter_test/flutter_test.dart';

String _hex(List<int> b) =>
    b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();

int _prop(Uint8List f) =>
    ByteData.sublistView(f).getUint32(14, Endian.little);

/// tools/dash_up.py 按同一顺序输出的 18 帧（2026-11-05 diff 为空）。
const _reference = <String>[
  'fe5aaaa511027501010022002000021070210000000053572e312e30302e353620414535490000000000000000003ca5555a',
  'fe5aaaa51102750101000e000c0010734121000000000100000075a5555a',
  'fe5aaaa51102750101000e000c000474402700000000ffffffff80a5555a',
  'fe5aaaa51102750101000e000c000177702100000000c000000092a5555a',
  'fe5aaaa51102750101000c000a00029770210000000008002da5555a',
  'fe5aaaa51102750101000e000c0021957021000000000000000014a5555a',
  'fe5aaaa51102750101000e000c0072704021000000000000000018a5555a',
  'fe5aaaa51102750101000e000c0030004021000000009900000031a5555a',
  'fe5aaaa5110275010100120010000696702100000000000400000000000022a5555a',
  'fe5aaaa51102750101001e001c000274702100000000000000000000000000000000000000000000000034a5555a',
  'fe5aaaa5110275010100220020001d95702100000000000000000000000000000000000000001900000000000000d7a5555a',
  'fe5aaaa5110275010100220020001d95702100000000000000000100000000000000000000001900000000000000d6a5555a',
  'fe5aaaa51102750101001e001c002d9570210000000000015b1e1e000000000000c012000000000000007ea5555a',
  'fe5aaaa51102750101001a00180000967021000000005b5b5b000000000000000000000000000ba5555a',
  'fe5aaaa5110275010100220020000174702100000000c4130000000000001f01000000000000000000000000000036a5555a',
  'fe5aaaa511027501010022002000030070210000000064000000000000002300000000000000000000000000000018a5555a',
  'fe5aaaa511027501010010000e0021717021000000001a0b05060e05f1a5555a',
  'fe5aaaa51102750101001a0018001e9570210000000001000000000000000000000000000000fea5555a',
];

List<Uint8List> _allFrames() {
  final t = DashTelemetry();
  return [
    ...dashBootFrames(t),
    dashSyncFrame(true),
    dashVi1Frame(t),
    dashVi2Frame(t, gear: 0),
    dashVi2Frame(t, gear: 1),
    dashVi3Frame(t),
    dashBattFrame(t),
    dashOdoFrame(t),
    dashTripFrame(t),
    dashPropFrame(DashProp.rtc, [26, 11, 5, 6, 14, 5]),
    dashLampFrame(DashTelemetry(lampHex: '01'))!,
  ];
}

void main() {
  test('18 帧与 tools/dash_up.py 逐字节一致', () {
    final frames = _allFrames();
    expect(frames.length, _reference.length);
    for (var i = 0; i < frames.length; i++) {
      expect(_hex(frames[i]), _reference[i], reason: 'frame #$i');
    }
  });

  test('每帧头/尾/校验和合法', () {
    for (final f in _allFrames()) {
      expect(_hex(f.sublist(0, 4)), 'fe5aaaa5');
      expect(_hex(f.sublist(f.length - 3)), 'a5555a');
      var sum = 0;
      for (var i = 4; i < f.length - 4; i++) {
        sum += f[i];
      }
      expect(f[f.length - 4], (~sum) & 0xff);
    }
  });

  test('上屏数值来自 DashTelemetry（MCU 仿真数据源，不是硬编码贴图）', () {
    final t = DashTelemetry(
      soc: 42,
      odoX10: 1234,
      driveMode: 3,
      range: 100,
      gear: 1,
    );
    final batt = dashBattFrame(t);
    expect(batt[22], 42);
    expect(batt[23], 42);
    expect(batt[24], 42); // [2] = 底栏电量百分比
    final vi3 = dashVi3Frame(t);
    expect(vi3[23], 3); // [1] = drive_mode
    expect(vi3[24], 42); // [2] = battery
    final odo = dashOdoFrame(t);
    expect(ByteData.sublistView(odo).getUint32(22, Endian.little), 1234);
    final vi2 = dashVi2Frame(t, gear: t.gear);
    expect(vi2[26], 1); // [4] = gear
    expect(ByteData.sublistView(vi2).getUint32(30, Endian.little), 100);
  });

  test('三段式进场：pre-arm 不喂解锁 / settle 20 拍 gear=0 / enter 只一次 gear=1',
      () async {
    final sent = <Uint8List>[];
    int? bootAt;
    late DashUpFeeder feeder;
    feeder = DashUpFeeder(
      send: (f) async => sent.add(f),
      paintedPct: () => 0.5, // 首帧已出，pre-arm 立即收尾
      preArmTimeout: const Duration(seconds: 1),
      onPhase: (p, _) {
        if (p == DashUpPhase.boot) bootAt ??= sent.length;
        if (p == DashUpPhase.hold) feeder.stop();
      },
    );
    await feeder.start().timeout(const Duration(seconds: 20));

    expect(bootAt, isNotNull);
    // pre-arm 阶段出现解锁通知 → 进场动画被拆帧渲染成整车拖尾。
    expect(
      sent.take(bootAt!).where((f) => _prop(f) == DashProp.sync),
      isEmpty,
      reason: 'pre-arm 禁喂 synchronization_status',
    );
    final vi2 = sent.where((f) => _prop(f) == DashProp.vi2).toList();
    expect(vi2.where((f) => f[26] == 0).length, 20);
    expect(
      vi2.where((f) => f[26] == 1).length,
      1,
      reason: '反复写 gear 会让 slot_delayUpdateGear 重摆顶部 DRL/ECO，图标叠成双份',
    );
    // 保持期持续补 KL15 / 心跳，但不再写挡位。
    expect(sent.where((f) => _prop(f) == DashProp.kl15).length, greaterThan(2));
    expect(dashKeepFrames(DashTelemetry()).any((f) => _prop(f) == DashProp.vi2),
        isFalse);
  });
}
