// 模拟 MCU 的车身按键语义：转向/双闪/远光/定速/档位的互斥与边界。
//
// 这一层不产生 CFCP 车辆信号帧（未解码），所以测试只锁"状态机语义"和
// "日志可读性"，不假装仪表会亮灯。

import 'package:flutter_test/flutter_test.dart';
import 'package:ae5i_emu/emu/mcu.dart';

void main() {
  late McuSim sim;

  setUp(() => sim = McuSim());
  tearDown(() => sim.dispose());

  test('初始状态：车身功能全灭，不猜测档位', () {
    final s = sim.state.value;
    expect(s.hazard, isFalse);
    expect(s.leftTurn, isFalse);
    expect(s.rightTurn, isFalse);
    expect(s.highBeam, isFalse);
    expect(s.cruise, isFalse);
    expect(s.leftLamp, isFalse);
    expect(s.rightLamp, isFalse);
  });

  test('左右转向互斥：按右会灭左', () {
    sim.press(McuKey.turnLeft);
    expect(sim.state.value.leftTurn, isTrue);
    expect(sim.state.value.rightTurn, isFalse);

    sim.press(McuKey.turnRight);
    expect(sim.state.value.leftTurn, isFalse);
    expect(sim.state.value.rightTurn, isTrue);

    // 再按一次同一个键 = 取消
    sim.press(McuKey.turnRight);
    expect(sim.state.value.rightTurn, isFalse);
  });

  test('双闪点亮两侧指示灯，并按一次关掉', () {
    final on = sim.press(McuKey.hazard);
    expect(on.lines.single, contains('双闪 ON'));
    expect(sim.state.value.leftLamp, isTrue);
    expect(sim.state.value.rightLamp, isTrue);

    final off = sim.press(McuKey.hazard);
    expect(off.lines.single, contains('双闪 OFF'));
    expect(sim.state.value.leftLamp, isFalse);
    expect(sim.state.value.rightLamp, isFalse);
  });

  test('双闪优先：开着双闪时拨转向 = 关双闪并只亮那一侧', () {
    sim.press(McuKey.hazard);
    final r = sim.press(McuKey.turnLeft);
    expect(r.lines.single, contains('双闪 OFF'));
    expect(sim.state.value.hazard, isFalse);
    expect(sim.state.value.leftLamp, isTrue);
    expect(sim.state.value.rightLamp, isFalse);
  });

  test('远光与定速是独立开关', () {
    sim.press(McuKey.highBeam);
    sim.press(McuKey.cruise);
    expect(sim.state.value.highBeam, isTrue);
    expect(sim.state.value.cruise, isTrue);
    sim.press(McuKey.highBeam);
    expect(sim.state.value.highBeam, isFalse);
    expect(sim.state.value.cruise, isTrue);
  });

  test('加减拨杆不推断三档，改由电控 drive_mode 上报', () {
    final before = sim.state.value;
    for (final key in [McuKey.gearUp, McuKey.gearDown]) {
      final r = sim.press(key);
      expect(r.stateChanged, isFalse);
      expect(r.lines.single, contains('驾驶模式已随电控状态上报'));
      expect(sim.state.value, same(before));
    }
  });

  test('喇叭是无状态瞬时动作', () {
    final r = sim.press(McuKey.horn);
    expect(r.lines.single, contains('喇叭'));
    expect(r.stateChanged, isFalse);
  });

  test('自定义键切换 TCS，状态经 indicator_lamp 上行', () {
    final tap = sim.press(McuKey.custom);
    expect(tap.lines.single, contains('自定义'));
    expect(tap.lines.single, isNot(contains('长按')));
    expect(tap.lines.single, contains('indicator_lamp'));
    final long = sim.press(McuKey.custom, long: true);
    expect(long.lines.single, contains('长按'));
    expect(long.lines.single, contains('TCS'));
    expect(long.stateChanged, isFalse);
  });

  test('下电复位：转向/双闪/远光/定速全灭', () {
    sim.press(McuKey.hazard);
    sim.press(McuKey.highBeam);
    sim.press(McuKey.cruise);
    sim.press(McuKey.gearUp);
    sim.resetOnPowerOff();
    final s = sim.state.value;
    expect(s.hazard || s.leftTurn || s.rightTurn, isFalse);
    expect(s.highBeam, isFalse);
    expect(s.cruise, isFalse);
  });

  test('summary 汇总当前车身状态', () {
    sim.press(McuKey.hazard);
    sim.press(McuKey.gearUp);
    expect(sim.state.value.summary, '双闪');
  });
}
