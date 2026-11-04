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
  pass, // 超车灯：瞬时闪远光
  hazard, // 双闪：左右转向同时闪
  cruise, // 定速：开/关
  custom, // 自定义键：请求切信息组
  horn, // 喇叭：瞬时
  turnLeft, // 转向拨杆 ◀
  turnRight, // 转向拨杆 ▶
  highBeam, // 照明：远/近光
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
    this.cruise = false,
    this.passFlashUntil = Duration.zero,
  });

  final bool hazard;
  final bool leftTurn;
  final bool rightTurn;
  final bool highBeam;
  final bool cruise;

  /// 超车灯按压时刻（用于 UI 闪烁），Duration.zero 表示没在闪。
  final Duration passFlashUntil;

  /// 仪表顶部转向指示灯的实际状态：双闪时左右同时亮。
  bool get leftLamp => leftTurn || hazard;
  bool get rightLamp => rightTurn || hazard;

  McuState copyWith({
    bool? hazard,
    bool? leftTurn,
    bool? rightTurn,
    bool? highBeam,
    bool? cruise,
    Duration? passFlashUntil,
  }) {
    return McuState(
      hazard: hazard ?? this.hazard,
      leftTurn: leftTurn ?? this.leftTurn,
      rightTurn: rightTurn ?? this.rightTurn,
      highBeam: highBeam ?? this.highBeam,
      cruise: cruise ?? this.cruise,
      passFlashUntil: passFlashUntil ?? this.passFlashUntil,
    );
  }

  /// 一行摘要，给日志 / 状态条用。
  String get summary {
    final on = <String>[
      if (hazard) '双闪',
      if (leftTurn) '左转',
      if (rightTurn) '右转',
      if (highBeam) '远光',
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
  McuSim({Duration Function()? now}) : _now = now ?? (() => Duration.zero);

  final Duration Function() _now;
  final ValueNotifier<McuState> state = ValueNotifier(const McuState());

  void dispose() => state.dispose();

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
        final next = !s.highBeam;
        state.value = s.copyWith(highBeam: next);
        return McuPressResult([next ? 'MCU: 远光 ON' : 'MCU: 远光 OFF（近光）']);

      case McuKey.pass:
        state.value = s.copyWith(
          passFlashUntil: _now() + const Duration(milliseconds: 350),
        );
        return const McuPressResult(['MCU: 超车灯（闪远光一次）']);

      case McuKey.cruise:
        final next = !s.cruise;
        state.value = s.copyWith(cruise: next);
        return McuPressResult([next ? 'MCU: 定速 ON' : 'MCU: 定速 OFF']);

      case McuKey.horn:
        return const McuPressResult(['MCU: 喇叭（瞬时）'], stateChanged: false);

      case McuKey.gearUp:
      case McuKey.gearDown:
        // AE5i 无变速箱；拨杆功能和 P/READY/骑行模式不能互相替代。
        // 0x21709702 的 8/9/10 仅是候选数据，尚无原厂画面差分证明。
        return McuPressResult([
          'MCU: ${key == McuKey.gearUp ? '加档' : '减档'}拨杆已按下；'
              '原生模式映射待验证，不发送猜测档位',
        ], stateChanged: false);

      case McuKey.custom:
        return McuPressResult([
          long
              ? 'MCU: 自定义键长按（真车 = 功能码 7 切信息组，需 SetItem4，未接入）'
              : 'MCU: 自定义键（切信息组需 SetItem4 功能码 7，未接入）',
        ], stateChanged: false);
    }
  }

  /// 整车下电时清空车身状态。
  void resetOnPowerOff() {
    state.value = const McuState();
  }
}
