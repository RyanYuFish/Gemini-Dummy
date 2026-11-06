// 模拟 GD32 MCU 的车身功能（把手上的非仪表按键）。
//
// 为什么需要这一层：
//   设备的 `keymap.data`（QMAP v1，602 条）在 0xc0..0xff 只登记了 11 个 KeyID，
//   也就是仪表 Qt 侧只认 11 个键；其余 KeyID 由 `cfcp-keypad` 投递到 evdev 后
//   **没有任何 Qt 映射**，原厂 Launcher 完全不响应（实测：0xc0/0xc7/0xce/0xd0
//   之类的帧只产生 `[CFCP]CFCP_KEY:...` 内核回显，Launcher 无 keyPressEvent）。
//   真车上转向/双闪/远光/喇叭/定速/档位本来就是 GD32 直接执行，仪表只是"接收方"。
//
// 本模型的边界（重要）：
//   * 它维护的是**客户端仿真层**的车身状态，用于让把手按键有确定、可观察的语义；
//   * 车身状态 → 仪表 的翻译已单独落在 `gd32.dart`（CFCP 属性帧，字节格式已用
//     真机抓包校验）；本类只负责状态机，不直接碰串口；
//   * 任何"看起来车辆动了"的效果都必须来自 guest 真实绘制，不能在这里画。
//     灯态/档位的属性 id 取值是抓包推断、尚未在仪表上逐项确认，详见 gd32.dart。

import 'package:flutter/foundation.dart';

/// 真车把手上不经过仪表的按键（GD32 直接执行）。
enum McuKey {
  pass, // 超车灯：按住闪灯，松开熄灭；向前推由常亮状态表示
  passLatch, // 超车灯向前推 / 复位
  hazard, // 双闪：左右转向同时闪
  cruise, // 定速：开/关
  custom, // 自定义键：请求切信息组
  horn, // 喇叭：瞬时
  turnLeft, // 转向拨杆 ◀
  turnRight, // 转向拨杆 ▶
  highBeam, // 照明：短按远光，长按自动照明
  gearUp, // 加档
  gearDown, // 减档
}

/// 车身状态快照。全部是不可变值，`McuSim` 通过 `copyWith` 产生新状态。
@immutable
class McuState {
  const McuState({
    this.hazard = false,
    this.leftTurn = false,
    this.rightTurn = false,
    this.highBeam = false,
    this.autoLamp = false,
    this.passLight = false,
    this.passLatched = false,
    this.ready = false,
    this.cruise = false,
  });

  final bool hazard;
  final bool leftTurn;
  final bool rightTurn;
  final bool highBeam;
  final bool autoLamp;
  final bool passLight;
  final bool passLatched;
  final bool ready;
  final bool cruise;

  bool get passOn => passLight || passLatched;

  /// 仪表顶部转向指示灯的实际状态：双闪时左右同时亮。
  bool get leftLamp => leftTurn || hazard;
  bool get rightLamp => rightTurn || hazard;

  McuState copyWith({
    bool? hazard,
    bool? leftTurn,
    bool? rightTurn,
    bool? highBeam,
    bool? autoLamp,
    bool? passLight,
    bool? passLatched,
    bool? ready,
    bool? cruise,
  }) {
    return McuState(
      hazard: hazard ?? this.hazard,
      leftTurn: leftTurn ?? this.leftTurn,
      rightTurn: rightTurn ?? this.rightTurn,
      highBeam: highBeam ?? this.highBeam,
      autoLamp: autoLamp ?? this.autoLamp,
      passLight: passLight ?? this.passLight,
      passLatched: passLatched ?? this.passLatched,
      ready: ready ?? this.ready,
      cruise: cruise ?? this.cruise,
    );
  }

  /// 一行摘要，给日志 / 状态条用。
  String get summary {
    final on = <String>[
      if (hazard) '双闪',
      if (leftTurn) '左转',
      if (rightTurn) '右转',
      if (highBeam) '远光',
      if (autoLamp) '自动照明',
      if (passOn) '超车灯',
      if (cruise) '定速',
    ];
    return on.isEmpty ? '车身功能关闭' : on.join('/');
  }
}

/// 一次按键的结果：写进 MCU 日志的行（空列表 = 无副作用）。
class McuPressResult {
  const McuPressResult(this.lines, {this.stateChanged = true});

  final List<String> lines;
  final bool stateChanged;
}

/// GD32 MCU 的按键语义模型。
///
/// 只做"车身功能"，不碰 QEMU 生命周期；Ready 由 `QemuController` 的整车
/// 状态机处理，因此不在这里。
class McuSim {
  McuSim();
  final ValueNotifier<McuState> state = ValueNotifier(const McuState());

  void dispose() => state.dispose();

  void setReady(bool ready) {
    state.value = state.value.copyWith(ready: ready);
  }

  McuPressResult pressDown(McuKey key) {
    if (key != McuKey.pass) return press(key);
    if (state.value.passLight) {
      return const McuPressResult(['MCU: 超车灯仍按下'], stateChanged: false);
    }
    state.value = state.value.copyWith(passLight: true);
    return const McuPressResult(['MCU: 超车灯 ON（按住期间）']);
  }

  McuPressResult release(McuKey key) {
    if (key != McuKey.pass || !state.value.passLight) {
      return const McuPressResult([], stateChanged: false);
    }
    state.value = state.value.copyWith(passLight: false);
    return const McuPressResult(['MCU: 超车灯 OFF（松开）']);
  }

  /// 按住不放的时长需要被识别（自定义键 = 长按切信息组）。
  McuPressResult press(McuKey key, {bool long = false}) {
    final s = state.value;
    switch (key) {
      case McuKey.hazard:
        final next = !s.hazard;
        // 开双闪时取消单侧转向：真车双闪优先。
        state.value = s.copyWith(
          hazard: next,
          leftTurn: next ? false : s.leftTurn,
          rightTurn: next ? false : s.rightTurn,
        );
        return McuPressResult([next ? 'MCU: 双闪 ON（左右转向灯同时闪）' : 'MCU: 双闪 OFF']);

      case McuKey.turnLeft:
        if (s.hazard) {
          // 双闪优先的反向操作：关双闪的同时立刻点亮被拨的那一侧。
          state.value = s.copyWith(
            hazard: false,
            leftTurn: true,
            rightTurn: false,
          );
          return McuPressResult(['MCU: 双闪 OFF → 左转向 ON']);
        }
        final next = !s.leftTurn;
        state.value = s.copyWith(leftTurn: next, rightTurn: false);
        return McuPressResult([next ? 'MCU: 左转向 ON' : 'MCU: 左转向 OFF']);

      case McuKey.turnRight:
        if (s.hazard) {
          state.value = s.copyWith(
            hazard: false,
            leftTurn: false,
            rightTurn: true,
          );
          return McuPressResult(['MCU: 双闪 OFF → 右转向 ON']);
        }
        final next = !s.rightTurn;
        state.value = s.copyWith(rightTurn: next, leftTurn: false);
        return McuPressResult([next ? 'MCU: 右转向 ON' : 'MCU: 右转向 OFF']);

      case McuKey.highBeam:
        if (long) {
          final next = !s.autoLamp;
          state.value = s.copyWith(autoLamp: next);
          return McuPressResult([next ? 'MCU: 自动照明 ON' : 'MCU: 自动照明 OFF']);
        }
        final next = !s.highBeam;
        state.value = s.copyWith(highBeam: next);
        return McuPressResult([next ? 'MCU: 远光 ON' : 'MCU: 远光 OFF（近光）']);

      case McuKey.pass:
        return pressDown(key);

      case McuKey.passLatch:
        final next = !s.passLatched;
        state.value = s.copyWith(passLatched: next);
        return McuPressResult([next ? 'MCU: 超车灯向前推 ON' : 'MCU: 超车灯复位 OFF']);

      case McuKey.cruise:
        final next = !s.cruise;
        state.value = s.copyWith(cruise: next);
        return McuPressResult([next ? 'MCU: 定速 ON' : 'MCU: 定速 OFF']);

      case McuKey.horn:
        return const McuPressResult(['MCU: 喇叭（瞬时）'], stateChanged: false);

      case McuKey.gearUp:
      case McuKey.gearDown:
        // 2026-11-05：由 QemuController 写 vehicle_info3.drive_mode
        // （1=ECO / 2=STREET / 3=SPORT）并经电控状态立即上行。这里仍不注入
        // 未经验证的 0x21709702 猜测档位；AE5i 无变速箱。
        return McuPressResult([
          'MCU: ${key == McuKey.gearUp ? '加档' : '减档'}拨杆 → '
              '驾驶模式已随电控状态上报',
        ], stateChanged: false);

      case McuKey.custom:
        // 真车长按 = 功能码 7 切信息组（SetItem4，尚未接入）；仿真里用这个键
        // 切换 TCS 启用/关闭，状态经 indicator_lamp.TC 上报。
        return McuPressResult([
          'MCU: 自定义键${long ? '长按' : '短按'} → TCS 状态已随 '
              'indicator_lamp 上报',
        ], stateChanged: false);
    }
  }

  /// 整车下电时清空车身状态。
  void resetOnPowerOff() {
    state.value = const McuState();
  }
}
