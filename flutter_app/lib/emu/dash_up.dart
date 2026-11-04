// AE5I 仪表「点亮 + 进 P 档主界面」的 MCU 对端（Dart 版）。
//
// 这是 tools/dash_up.py 的正向移植，帧字节与 Python 版逐字节一致。
// 全部画面元素（蓝绿背景 / 右侧大 P / 整车 / 顶部光条 / 左列数据 / 底栏）
// 都由 guest 里原厂 DashTheme01 的 QGraphicsScene **自己画出来**；本文件只负责
// 按原车 MCU 的语义把车辆数据经 CFCP 上行喂进去，不合成、不重绘任何像素。
//
// 逆向结论（Gemini-Dummy/docs/EMULATION.md §41、§42）：
//   1. CFCP 是可靠链路：guest 发出的每一帧都必须 ACK，否则重传 3 次丢弃，
//      应用层拿不到属性（ACK 由 QemuController._handleCfcpFrame 负责）。
//   2. KL15 = 0x99（prop 0x21400030）才点亮 OSD。
//   3. ★ 解锁通知 0x21709606（8 B，byte[1] bit2）是
//      DashTheme01::slot_delayUpdateGear() 的硬闸门（sysState[1] bit6）。
//      不喂它，换挡/换场景全部无效，画面永远停在 4.37% 非黑的待机统计页。
//   4. 挡位 0x2170951d（vehicle_info2，24 B）的 byte[4] = gear，gear=1 触发
//      Animation_Pstart_init() → PGEARobj_showInit(true) → P 档主界面。
//   5. 三段式进场（缺一不可）：
//      ⓐ pre-arm：App 首帧之前只喂 KL15 + RTC，**禁喂解锁**，否则进场动画
//         被拆帧渲染成整车拖尾；同时避免时钟 item 首帧用 App 自带 12:00
//         画一遍、之后改时间留下 "3:2t00" 残影。
//      ⓑ settle：连发 20 拍全量数据，gear 固定 0，不触发任何场景动画。
//      ⓒ enter：**只写一次** gear=1，等进场动画跑完。反复写 gear 会让
//         slot_delayUpdateGear 重摆顶部 DRL/ECO → 图标叠成双份。
//   6. 模型侧双缓冲翻页必须 copy front→back（SP_FB_NO_FLIPCOPY 未设时默认开），
//      否则残留旧像素形成文字重影 / 整车拖尾。
//
// 本文件只依赖 dart:async / dart:typed_data / cfcp.dart（纯 Dart，无 Flutter），
// 因此 tool/dash_up_check.dart 可以直接起 QEMU + 本喂食器做端到端验收。

import 'dart:async';
import 'dart:typed_data';

import 'cfcp.dart';

/// MCU→SoC 上行属性 id（身份载荷法喂「第 i 字节=i」+ handler 日志回显实测）。
class DashProp {
  DashProp._();

  static const int kl15 = 0x21400030; // KL15_STATE（点火 / 整车就绪）
  static const int sync = 0x21709606; // synchronization_status（解锁闸门）
  static const int vi1 = 0x21707402; // vehicle_info1 (20 B)
  static const int vi2 = 0x2170951D; // vehicle_info2 (24 B) ← gear 在 byte[4]
  static const int vi3 = 0x2170952D; // vehicle_info3 (20 B)
  static const int odo = 0x21707401; // trip_total_ODO (24 B)
  static const int trip1 = 0x21700003; // trip_1 (24 B)
  static const int rtc = 0x21707121; // RTC (6 B) [yy,mm,dd,hh,mi,ss]
  static const int batt = 0x21709600; // power_battery (16 B) [2]=电量%
  static const int lampIn = 0x2170951E; // indicator_lamp (16 B) 上行指示灯
  static const int lamp = 0x21407072;
  static const int gearStatus = 0x21709702;
  static const int heartbeat = 0x21709521;
  static const int vehStatus = 0x21707701;
  static const int swVersion = 0x21701002;
  static const int handshake = 0x21417310;
  static const int capability = 0x27407404;
}

/// MCU 遥测数据源。
///
/// 这就是「MCU 仿真器」里的车辆数据：所有上屏数值都从这里经 CFCP 上行送给
/// 固件，由固件自己的 widget 渲染。改这里的值即可改变仪表显示（而不是重绘）。
///
/// 默认值取自 dash_up.py 的实车样本：电量 91%、总里程 506.0 km、
/// 平均电耗 28.7 Wh/km、单次里程 10.0 km、ECO 模式、P 挡。
class DashTelemetry {
  DashTelemetry({
    this.gear = 1,
    this.kl15 = 0x99,
    this.soc = 91,
    this.range = 0,
    this.ambTemp = 25,
    this.driveMode = 1,
    this.speed = 0,
    this.rpm = 0,
    this.motorTemp = 30,
    this.waterTemp = 0,
    this.odoX10 = 5060,
    this.avgPowerX10 = 287,
    this.tripX10 = 100,
    this.tripPowerX10 = 35,
    this.battVoltage = 4800,
    this.battCurrent = 0,
    this.chargingTime = 0,
    this.lampHex = '',
    this.rtcAuto = true,
  });

  /// 目标挡位：1 = P（主界面），0 = DASH / 统计页。
  int gear;

  /// KL15 状态，0x99 = 整车就绪 / 点亮 OSD。
  int kl15;

  /// 动力电池电量（%），同时写 vehicle_info3.battery 与 power_battery[2]。
  int soc;

  /// 续航 km（vehicle_info2.remind_milage）。
  ///
  /// 默认 0：固件先画 "0km"，非 0 值更宽，数字 item 只重画自己新文本的矩形，
  /// 会在左侧留下旧字。模型补齐 PFC 背景层之前保持 0 最干净。
  int range;

  /// 环境温度 ℃（vehicle_info2.ambTemperature）。
  int ambTemp;

  /// 驾驶模式：1=ECO 2=STREET 3=SPORT（vehicle_info3.drive_mode）。
  int driveMode;

  int speed;
  int rpm;
  int motorTemp;
  int waterTemp;

  /// 总里程 / 平均电耗 / 单次里程 / 单次电耗（均为 0.1 单位）。
  int odoX10;
  int avgPowerX10;
  int tripX10;
  int tripPowerX10;

  /// 动力电池电压（0.1 V）、电流、充电时长（min）。
  int battVoltage;
  int battCurrent;
  int chargingTime;

  /// indicator_lamp 16 B 位图（hex）。
  ///
  /// 默认空 = **不喂**。固件从不擦除旧像素，灯只能加不能减；且 ABS_fault
  /// 会弹故障框卡住 App。要在进场动画之后才喂一次。
  String lampHex;

  /// true = RTC 跟随宿主机本地时间（只在分钟翻页时重发）。
  bool rtcAuto;
}

// ------------------------------------------------------------------ 帧构造

Uint8List _buf(int n) => Uint8List(n);

void _u32(Uint8List b, int off, int v) =>
    ByteData.sublistView(b).setUint32(off, v & 0xFFFFFFFF, Endian.little);

void _i32(Uint8List b, int off, int v) =>
    ByteData.sublistView(b).setInt32(off, v, Endian.little);

void _u16(Uint8List b, int off, int v) =>
    ByteData.sublistView(b).setUint16(off, v & 0xFFFF, Endian.little);

/// 变长负载属性帧。
Uint8List dashPropFrame(int prop, List<int> value) =>
    cfcpPropFrame(prop, 0, rawValue: value);

/// u32 负载属性帧。
Uint8List dashU32Frame(int prop, int value) =>
    cfcpPropFrame(prop, 0, intValue: value);

/// vehicle_info1 (20 B)：[0..3] wheel_spd [4..7] inst_elec [12..15] rpm
/// [16..19] water_temp。
Uint8List dashVi1Frame(DashTelemetry t) {
  final b = _buf(20);
  _i32(b, 0, t.speed);
  _i32(b, 4, 0); // inst_elec_consume
  _i32(b, 12, t.rpm);
  _i32(b, 16, t.waterTemp);
  return dashPropFrame(DashProp.vi1, b);
}

/// vehicle_info2 (24 B)：[0..3] remaind_fuel  [4] ★gear
/// [8..11] remind_milage（底栏续航） [12..15] 12V 电压 [16..19] 环境温度。
Uint8List dashVi2Frame(DashTelemetry t, {required int gear}) {
  final b = _buf(24);
  _u32(b, 0, 0); // remaind_fuel
  b[4] = gear & 0xFF;
  _u32(b, 8, t.range);
  _u32(b, 12, 0); // batt_12v_voltage
  _i32(b, 16, t.ambTemp);
  return dashPropFrame(DashProp.vi2, b);
}

/// vehicle_info3 (20 B)：[1] drive_mode [2] battery [3..4] 电机温度
/// [11..12] 电压 [13..14] 电流 [15..16] 充电时长。
Uint8List dashVi3Frame(DashTelemetry t) {
  final b = _buf(20);
  b[1] = t.driveMode & 0xFF;
  b[2] = t.soc & 0xFF;
  b[3] = t.motorTemp & 0xFF;
  b[4] = t.motorTemp & 0xFF;
  _u16(b, 11, t.battVoltage);
  _u16(b, 13, t.battCurrent);
  _u16(b, 15, t.chargingTime);
  return dashPropFrame(DashProp.vi3, b);
}

/// power_battery (16 B)：[0] level1 [1] level2 [2] all(%) ← 底栏电量。
Uint8List dashBattFrame(DashTelemetry t) {
  final b = _buf(16);
  b[0] = t.soc & 0xFF;
  b[1] = t.soc & 0xFF;
  b[2] = t.soc & 0xFF;
  return dashPropFrame(DashProp.batt, b);
}

/// synchronization_status (8 B)：byte[1] bit2 = UNLOCK_NOTIFY
/// → sysState[1] bit6，放行 slot_delayUpdateGear。
Uint8List dashSyncFrame(bool unlock) {
  final b = _buf(8);
  if (unlock) b[1] |= 0x04;
  return dashPropFrame(DashProp.sync, b);
}

/// trip_total_ODO (24 B)：[0..3] odo [8..11] avg_power（左列平均电耗）。
Uint8List dashOdoFrame(DashTelemetry t) {
  final b = _buf(24);
  _u32(b, 0, t.odoX10);
  _u32(b, 4, 0); // avg fuel consume
  _u32(b, 8, t.avgPowerX10);
  _u32(b, 12, t.speed);
  _u32(b, 16, 0); // drivetime
  return dashPropFrame(DashProp.odo, b);
}

/// trip_1 (24 B)：布局同 trip_total_ODO。
Uint8List dashTripFrame(DashTelemetry t) {
  final b = _buf(24);
  _u32(b, 0, t.tripX10);
  _u32(b, 4, 0); // avg fuel
  _u32(b, 8, t.tripPowerX10);
  _u32(b, 12, t.speed);
  _u32(b, 16, 0); // drivetime
  return dashPropFrame(DashProp.trip1, b);
}

/// RTC (6 B)：[yy,mm,dd,hh,mi,ss]。auto 时跟随宿主机本地时间。
Uint8List dashRtcFrame(DashTelemetry t) {
  final now = DateTime.now();
  return dashPropFrame(DashProp.rtc, [
    now.year % 100,
    now.month,
    now.day,
    now.hour,
    now.minute,
    now.second,
  ]);
}

/// indicator_lamp (16 B)。hex 为空时返回 null（默认不喂，避免固件留下残灯）。
Uint8List? dashLampFrame(DashTelemetry t) {
  var s = t.lampHex.replaceAll(' ', '');
  if (s.isEmpty) return null;
  if (s.length.isOdd) s = '0$s';
  final data = _buf(16);
  for (var i = 0; i < 16 && i * 2 + 1 < s.length; i++) {
    data[i] = int.tryParse(s.substring(i * 2, i * 2 + 2), radix: 16) ?? 0;
  }
  return dashPropFrame(DashProp.lampIn, data);
}

/// 上电基线：版本 / 握手 / 能力 / 状态 / 挡位状态 / 心跳 / 灯态 / KL15。
///
/// 与真机 MCU 上电时上报的顺序一致；KL15=0x99 是点亮 OSD 的必要条件。
List<Uint8List> dashBootFrames(DashTelemetry t) => [
  cfcpPropFrame(DashProp.swVersion, 0,
      strValue: 'SW.1.00.56 AE5I', strLen: 24),
  dashU32Frame(DashProp.handshake, 1),
  dashU32Frame(DashProp.capability, 0xFFFFFFFF),
  dashU32Frame(DashProp.vehStatus, 0xC0),
  dashPropFrame(DashProp.gearStatus, const [8, 0]),
  dashU32Frame(DashProp.heartbeat, 0),
  dashU32Frame(DashProp.lamp, 0),
  dashU32Frame(DashProp.kl15, t.kl15),
];

/// 一拍全量车辆数据（settle 阶段 gear 固定 0）。
List<Uint8List> dashDataFrames(DashTelemetry t, {required int gear}) => [
  dashVi2Frame(t, gear: gear),
  dashVi1Frame(t),
  dashVi3Frame(t),
  dashBattFrame(t),
  dashOdoFrame(t),
  dashTripFrame(t),
];

/// 保持期每 0.5 s 的心跳/数据（**绝不重复写挡位**）。
List<Uint8List> dashKeepFrames(DashTelemetry t) => [
  dashU32Frame(DashProp.kl15, t.kl15),
  dashU32Frame(DashProp.heartbeat, 0),
  dashVi1Frame(t),
  dashVi3Frame(t),
  dashBattFrame(t),
  dashOdoFrame(t),
  dashTripFrame(t),
];

// ------------------------------------------------------------------ 喂食器

enum DashUpPhase {
  idle,
  preArm,
  boot,
  unlock,
  settle,
  enter,
  hold,
  healing,
  stopped,
}

/// 帧发送回调（由 QemuController 经 _cfcpSend 串行写进 ttyS1）。
typedef DashSend = Future<void> Function(Uint8List frame);

/// MCU 对端状态机：三段式进场 + 保持 + 自愈。
///
/// 设计成纯 Dart（无 Flutter 依赖）以便端到端验收脚本直接复用。
class DashUpFeeder {
  DashUpFeeder({
    required this.send,
    required this.paintedPct,
    this.animating = _false,
    this.onLog = _noopLog,
    this.onPhase = _noopPhase,
    DashTelemetry? telemetry,
    this.preArmTimeout = const Duration(seconds: 25),
  }) : telemetry = telemetry ?? DashTelemetry();

  final DashSend send;

  /// 当前帧非黑像素占比（0.0–1.0）。app 里读 displayPaintedPct，
  /// 端到端脚本里读 SP_FB_FRAME 的 PPM。
  final double Function() paintedPct;

  /// 模型是否正在重放 bootloader logo（此时非黑像素不算 App 首帧）。
  final bool Function() animating;

  final void Function(String) onLog;
  final void Function(DashUpPhase, String) onPhase;

  /// MCU 遥测数据源；运行中改字段即刻影响后续心跳上报的数值。
  final DashTelemetry telemetry;

  final Duration preArmTimeout;

  static bool _false() => false;
  static void _noopLog(String _) {}
  static void _noopPhase(DashUpPhase _, String _) {}

  bool _stopped = false;
  Future<void>? _runFuture;
  DashUpPhase _phase = DashUpPhase.idle;
  int _lastRtcMinute = -1;

  DashUpPhase get phase => _phase;
  bool get stopped => _stopped;

  /// 进场序列已完成的标记（供 UI 判断"画面确实亮了"）。
  bool entered = false;

  Future<void> start() => _runFuture ??= _run();

  void stop() {
    _stopped = true;
    _setPhase(DashUpPhase.stopped, 'MCU 对端停止');
  }

  void _setPhase(DashUpPhase p, String msg) {
    _phase = p;
    onPhase(p, msg);
    onLog('DashUp: $msg');
  }

  Future<void> _sleep(Duration d) => Future<void>.delayed(d);

  Future<void> _send(Uint8List f) async {
    if (_stopped) return;
    await send(f);
  }

  Future<void> _sendAll(List<Uint8List> frames) async {
    for (final f in frames) {
      if (_stopped) return;
      await _send(f);
    }
  }

  Future<void> _run() async {
    try {
      await _preArm();
      if (_stopped) return;
      await _bootUnlock();
      if (_stopped) return;
      await _burst(20, const Duration(milliseconds: 150), DashUpPhase.settle);
      if (_stopped) return;
      await _enter();
      if (_stopped) return;
      await _hold();
    } catch (e) {
      onLog('DashUp 异常：$e');
    }
  }

  /// ⓐ pre-arm：App 首帧之前只喂 KL15 + RTC，**禁喂解锁**。
  Future<void> _preArm() async {
    _setPhase(DashUpPhase.preArm,
        'pre-arm：KL15 + RTC 灌入（不喂解锁，保证进场动画不被拆帧）');
    await _sendAll(dashBootFrames(telemetry));
    await _sleep(const Duration(milliseconds: 250));
    final deadline = DateTime.now().add(preArmTimeout);
    while (!_stopped && DateTime.now().isBefore(deadline)) {
      await _send(dashU32Frame(DashProp.kl15, telemetry.kl15));
      await _send(dashRtcFrame(telemetry));
      await _sleep(const Duration(milliseconds: 200));
      final p = paintedPct();
      if (p > 0.03 && !animating()) {
        onLog('DashUp: App 首帧已出现（非黑 ${(p * 100).toStringAsFixed(1)}%）');
        return;
      }
    }
    onLog('DashUp: pre-arm 等待超时，按既定序列继续进场');
  }

  /// ⓑ 基线重放 + ★解锁通知。
  Future<void> _bootUnlock() async {
    _setPhase(DashUpPhase.boot, '重放上电基线（版本/握手/能力/状态/KL15）');
    await _sendAll(dashBootFrames(telemetry));
    await _sleep(const Duration(milliseconds: 350));
    _setPhase(DashUpPhase.unlock,
        '喂 synchronization_status 解锁通知（放行 slot_delayUpdateGear）');
    await _send(dashSyncFrame(true));
    await _sleep(const Duration(milliseconds: 350));
  }

  /// settle：连发 n 拍全量数据，gear 固定 0，不触发场景动画。
  Future<void> _burst(int n, Duration step, DashUpPhase phase) async {
    _setPhase(phase, '$n 拍全量车辆数据，挡位固定 0（不触发场景动画）');
    for (var i = 0; i < n && !_stopped; i++) {
      await _sendAll(dashDataFrames(telemetry, gear: 0));
      await _sleep(step);
    }
  }

  /// ⓒ enter：**只写一次** gear，然后耐心等进场动画跑完。
  Future<void> _enter() async {
    _setPhase(DashUpPhase.enter,
        '只写一次 gear=${telemetry.gear}，触发 PGEAR 进场动画');
    await _send(dashVi2Frame(telemetry, gear: telemetry.gear));
    await _send(dashRtcFrame(telemetry));
    await _sleep(const Duration(milliseconds: 400));
    // 指示灯必须等进场动画跑完再喂（提前喂会让 App 重建场景，把
    // "骑行获得数据~" 占位文字压在真值下面）。默认 lampHex 为空 = 不喂。
    final lamp = dashLampFrame(telemetry);
    if (lamp != null) {
      await _sleep(const Duration(milliseconds: 2500));
      await _send(lamp);
      await _sleep(const Duration(milliseconds: 600));
    }
    entered = true;
    _setPhase(DashUpPhase.hold, 'P 档主界面由固件自身渲染完成，进入保持/自愈');
  }

  /// 保持：0.5 s 心跳与数据，挡位绝不重复写；3 s 一次画面体检与自愈。
  Future<void> _hold() async {
    var lastKeep = DateTime.now().subtract(const Duration(seconds: 1));
    var lastReport = DateTime.now();
    var wasUp = true;
    var lowStreak = 0;
    while (!_stopped) {
      await _sleep(const Duration(milliseconds: 20));
      final now = DateTime.now();
      if (now.difference(lastKeep) >= const Duration(milliseconds: 500)) {
        await _sendAll(dashKeepFrames(telemetry));
        // RTC 只在分钟翻页时补一发；每 0.5 s 重发会扰动 App 的定时器。
        if (telemetry.rtcAuto && now.minute != _lastRtcMinute) {
          _lastRtcMinute = now.minute;
          await _send(dashRtcFrame(telemetry));
        }
        // 解锁闸门位在 Launcher 重启后归零，保持期需要持续补。
        await _send(dashSyncFrame(true));
        lastKeep = now;
      }
      if (now.difference(lastReport) >= const Duration(seconds: 3)) {
        final p = paintedPct();
        if (p >= 0.15) {
          wasUp = true;
          lowStreak = 0;
        } else if (wasUp) {
          lowStreak++;
        }
        // Launcher 每隔约 2 分钟重启一次，重启后 sysState/挡位归零，画面会
        // 掉回 ~4% 的待机统计页。连续 3 次检测到就重放一次上电序列。
        if (wasUp && lowStreak >= 3) {
          await _heal();
          lowStreak = 0;
          wasUp = false;
        }
        lastReport = now;
      }
    }
  }

  Future<void> _heal() async {
    _setPhase(DashUpPhase.healing, '画面掉回待机，重放上电 + 解锁 + 挡位序列');
    await _sendAll(dashBootFrames(telemetry));
    await _sleep(const Duration(milliseconds: 300));
    await _send(dashSyncFrame(true));
    await _sleep(const Duration(milliseconds: 200));
    await _send(dashU32Frame(DashProp.kl15, telemetry.kl15));
    await _burst(20, const Duration(milliseconds: 120), DashUpPhase.healing);
    await _send(dashVi2Frame(telemetry, gear: telemetry.gear));
    await _sleep(const Duration(milliseconds: 400));
  }
}
