// 把手按键表 —— 与设备固件对齐后的版本（2026-11-01 重做）。
//
// 真车链路：把手开关 → GD32 MCU → CFCP KeyID 帧（/dev/ttyS1）→ cfcp-keypad →
// Linux input → Qt。仪表只消费**它认识的** KeyID，其余按键在 MCU 侧执行。
//
// 证据（两条互相独立，结论一致）：
//   1. `[CFCP]CFCP_KEY:*** KeyID(0x%x),KeyValue(0x%x)` 是内核回显，任何 KeyID
//      都会打印，所以"能看到回显"不等于"仪表响应"。
//   2. 设备 `/application/keymap/keymap.data` 是 Qt QMAP v1（602 条），0xc0..0xff
//      区间只有 11 条，正好是下面 `ClusterKeys` 里列出的 11 个 KeyID；不在表里的
//      KeyID 到 evdev 后没有 Qt 映射，原厂 Launcher 不会产生 keyPressEvent。
//   3. 逐键实测（0x00..0xff 全扫 + 单键复测）Launcher 的动作名：
//        0xd2 app_key_up    0xd3 app_key_down
//        0xd4 app_key_right 0xd5 app_key_left   （right 触发 clickEnter + 换主题）
//        0xd6 app_key_ota   0xd7 app_key_960
//        0xc8/0xcf/0xc9/0xd1/0xdf 有 keyPressEvent 但没有命名动作，画面无变化。
//
// 所以：面板上除上/下/SET/BACK 之外的键，**在真车上本来就不经过仪表**，它们由
// GD32 执行 → 客户端用 `McuSim` 建模（见 emu/mcu.dart），而不是往串口塞帧。

import 'mcu.dart';

/// 仪表（Qt）真正消费的 CFCP KeyID。
class ClusterKeys {
  const ClusterKeys._();

  static const int up = 0xd2; // app_key_up
  static const int down = 0xd3; // app_key_down
  static const int right = 0xd4; // app_key_right = 确认方向（clickEnter / 换主题）
  static const int left = 0xd5; // app_key_left  = 返回方向
  static const int ota = 0xd6; // app_key_ota
  static const int ota960 = 0xd7; // app_key_960

  /// keymap.data 里有映射、但没有命中命名动作的 5 个键（保留观察，不给 UI 入口）。
  static const List<int> reserved = [0xc8, 0xc9, 0xcf, 0xd1, 0xdf];

  /// 全部 11 个仪表侧 KeyID。
  static List<int> get all => [up, down, right, left, ota, ota960, ...reserved];

  /// Launcher 里对应的动作名（未命名的给 null）。
  static String? actionName(int keyId) => switch (keyId) {
    up => 'app_key_up',
    down => 'app_key_down',
    right => 'app_key_right',
    left => 'app_key_left',
    ota => 'app_key_ota',
    ota960 => 'app_key_960',
    _ => null,
  };
}

class InstrumentKey {
  final String label;
  final String sub;

  /// 仪表侧 CFCP KeyID；null = 真车上该键不经过仪表。
  final int? code;

  /// MCU 侧功能；只有 [code] == null 时才有效。
  final McuKey? mcu;

  const InstrumentKey(this.label, this.sub, this.code, {this.mcu});

  /// 这个键能不能产生确定的行为（仪表帧或 MCU 模型）。
  bool get supported => code != null || mcu != null;

  /// 是否有独立的**长按**语义（真车长按 ≠ 短按）。
  ///
  /// 只有「自定义键」（长按 = 功能码 7 切信息组）和「启动」（长按 Ready）需要；
  /// 其余键都不能因为按住时间变长而动作两次 —— 双闪之类是翻转语义，多触发一次
  /// 就会连开连关。
  bool get hasLongPress => mcu == McuKey.custom || label == '启动';

  /// 短标签：给按键角标用。
  String get badge {
    if (code != null) return 'CFCP 0x${code!.toRadixString(16)}';
    return 'MCU';
  }
}

class KeyGroup {
  final String title;
  final String detail;
  final List<InstrumentKey> keys;
  const KeyGroup(this.title, this.detail, this.keys);
}

/// 依据：车主现场确认 + `instruction/page79-elec.jpg` 电气原理图。
const List<KeyGroup> kGroups = [
  KeyGroup('左把手', '10 个实体控件 · 转向拨杆分左右', [
    InstrumentKey('超车灯', 'Pass', null, mcu: McuKey.pass),
    InstrumentKey('双闪', 'Hazard', null, mcu: McuKey.hazard),
    InstrumentKey('上', 'Up', ClusterKeys.up),
    InstrumentKey('定速', 'Cruise', null, mcu: McuKey.cruise),
    InstrumentKey('自定义键', 'Custom', null, mcu: McuKey.custom),
    InstrumentKey('SET', '确认 / ►', ClusterKeys.right),
    InstrumentKey('BACK', '返回 / ◄', ClusterKeys.left),
    InstrumentKey('下', 'Down', ClusterKeys.down),
    InstrumentKey('拨杆 ◀', '左转向', null, mcu: McuKey.turnLeft),
    InstrumentKey('拨杆 ▶', '右转向', null, mcu: McuKey.turnRight),
    InstrumentKey('喇叭', 'Horn', null, mcu: McuKey.horn),
  ]),
  KeyGroup('右把手', '3 个实体控件 · 档位拨杆分加减', [
    InstrumentKey('照明', '远 / 近光', null, mcu: McuKey.highBeam),
    InstrumentKey('加档', 'Gear +', null, mcu: McuKey.gearUp),
    InstrumentKey('减档', 'Gear −', null, mcu: McuKey.gearDown),
    InstrumentKey('启动', 'Ready', null),
  ]),
];

/// 扁平视图，测试用。
List<InstrumentKey> get kKeys => [for (final g in kGroups) ...g.keys];
