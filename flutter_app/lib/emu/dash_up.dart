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
import 'password.dart';

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
  /// Power_On_Passwd（开机密码，6 B）。`mcucom_tx_power_on_passwd` 与
  /// `mcucom_rx_power_on_passwd_handle` 共用同一个 id，双向语义由 byte[4] 区分。
  static const int powerOnPasswd = 0x21709701;
  static const int heartbeat = 0x21709521;
  static const int vehStatus = 0x21707701;
  static const int swVersion = 0x21701002;
  static const int handshake = 0x21417310;
  static const int capability = 0x27407404;
}

/// 电机控制器（电控 MCU）上报的**车辆状态**，对应 `indicator_lamp`
/// (`0x2170951e`, 16 B)。
///
/// 字段布局由「单 bit 载荷 + 固件日志 diff」逐位解出（tools/lamp_bits.py，
/// 2026-11-05，108 个语义位 / 40 个字段）：
///   * byte0..3 各是一个**整字节数值**字段：ABS_off / ABS_fault / camera / TC；
///   * byte4..14 每字节装 4 个 **2-bit 字段**（0=灭 1=亮 2=告警），
///     编码为 `value << bit0`；
///   * byte15 未解出，保持 0。
///
/// `TC` 就是用户说的「TCS 启用与否」；`parking`/`EV_READY`/`turn_*`/
/// `high_beam`/`CruiseControl` 是档位与把手按键对应的状态 icon 源。
///
/// ⚠ `ABS_fault` 置位会弹故障框卡住 App，恒 0。本类只产生状态字节，
/// **不画任何像素**；icon 一律由 guest 原厂 widget 自己渲染。
class MotorStatus {
  MotorStatus({this.tc = 1, this.parking = 1});

  // ---- byte0..3：整字节数值字段 ----
  int absOff = 0;
  int absFault = 0; // 恒 0：置位会弹故障框
  int camera = 0;

  /// TCS 状态：1 = 启用，2 = 关闭（顶部 TC-off 图标）。
  int tc;

  // ---- byte4..14：2-bit 字段（0 / 1 / 2）----
  int otaNotRegist = 0;
  int vinNotWrite = 0;
  int sideStand = 0;
  int evReady = 0;
  int autoStartStop = 0;
  int engineKill = 0;
  int cruiseControl = 0;
  int windWing = 0;
  int autoLamp = 0;
  int downhill = 0;
  int powerLimiting = 0;
  int powerBatteryFault = 0;
  int powerBatteryCutOff = 0;
  int lowBrakeFluid = 0;
  int discharging = 0;
  int charging = 0;
  int electricityConnect = 0;
  int parking;
  int boosting = 0;
  int lowEngineOil = 0;
  int epsFault = 0;
  int lowVoltage = 0;
  int lowCharge = 0;
  int batteryFault = 0;
  int opcAlarm = 0;
  int posLight = 0;
  int bigLight = 0;
  int turnRight = 0;
  int turnLeft = 0;
  int highBeam = 0;
  int reverseAssistPower = 0;
  int promotionAssist = 0;
  int engineFault = 0;
  int rcwWarnStatus = 0;
  int bluetoothKey = 0;
  int seatCushionLockControl = 0;
  int turtleSpeedDrivingLight = 0;
  int bsdStatus = 0;

  void _set2(Uint8List b, int byte, int bit0, int value) =>
      b[byte] = (b[byte] | ((value & 3) << bit0)) & 0xFF;

  Uint8List encode() {
    final b = _buf(16);
    b[0] = absOff & 0xFF;
    b[1] = absFault & 0xFF;
    b[2] = camera & 0xFF;
    b[3] = tc & 0xFF;
    _set2(b, 4, 0, otaNotRegist);
    _set2(b, 4, 2, vinNotWrite);
    _set2(b, 4, 4, sideStand);
    _set2(b, 4, 6, evReady);
    _set2(b, 5, 2, autoStartStop);
    _set2(b, 5, 4, engineKill);
    _set2(b, 5, 6, cruiseControl);
    _set2(b, 6, 0, windWing);
    _set2(b, 6, 6, autoLamp);
    _set2(b, 7, 0, downhill);
    _set2(b, 7, 2, powerLimiting);
    _set2(b, 7, 4, powerBatteryFault);
    _set2(b, 7, 6, powerBatteryCutOff);
    _set2(b, 8, 0, lowBrakeFluid);
    _set2(b, 8, 2, discharging);
    _set2(b, 8, 4, charging);
    _set2(b, 8, 6, electricityConnect);
    _set2(b, 9, 0, parking);
    _set2(b, 9, 2, boosting);
    _set2(b, 9, 4, lowEngineOil);
    _set2(b, 9, 6, epsFault);
    _set2(b, 10, 0, lowVoltage);
    _set2(b, 10, 2, lowCharge);
    _set2(b, 10, 4, batteryFault);
    _set2(b, 10, 6, opcAlarm);
    _set2(b, 11, 0, posLight);
    _set2(b, 11, 2, bigLight);
    _set2(b, 11, 4, turnRight);
    _set2(b, 11, 6, turnLeft);
    _set2(b, 12, 0, highBeam);
    _set2(b, 12, 2, reverseAssistPower);
    _set2(b, 12, 4, promotionAssist);
    _set2(b, 12, 6, engineFault);
    _set2(b, 13, 0, rcwWarnStatus);
    _set2(b, 13, 2, bluetoothKey);
    _set2(b, 13, 4, seatCushionLockControl);
    _set2(b, 13, 6, turtleSpeedDrivingLight);
    _set2(b, 14, 6, bsdStatus);
    return b;
  }

  /// 一行摘要，给日志 / 客户端状态条用。
  String get summary {
    final on = <String>[
      if (tc == 2) 'TCS 关闭' else if (tc == 1) 'TCS 启用',
      if (evReady > 0) 'READY',
      if (parking > 0) 'P 挡驻车',
      if (turnLeft > 0) '左转',
      if (turnRight > 0) '右转',
      if (highBeam > 0) '远光',
      if (bigLight > 0) '大灯',
      if (cruiseControl > 0) '定速',
    ];
    return on.isEmpty ? '电控无状态位' : on.join(' / ');
  }
}

/// MCU 遥测数据源。
///
/// 这就是「电机控制器 + BMS 仿真器」里的车辆数据：车速 / 档位 / 驾驶模式 /
/// TCS / 灯态全部从这里经 CFCP 上行送给固件，由固件自己的 widget 渲染。
/// 改这里的值即可改变仪表显示（而不是重绘）。
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

  /// 电机控制器状态（TCS / READY / 驻车 / 转向 / 远光 / 定速 …）。
  ///
  /// 2026-11-05 补齐：旧版默认**整个属性都不喂**，仪表收不到任何电控状态，
  /// 顶部状态区因此没有 icon 可画。现在进场动画跑完后恒上报，并由把手
  /// 按键实时改写（[DashUpFeeder.motorChanged]）。
  final motor = MotorStatus();

  /// 可选的 16 B hex 覆盖（诊断用）。空 = 使用 [motor] 的语义状态。
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

/// Power_On_Passwd (6 B)：[0..3] 4 位密码（ASCII 数字） [4] 状态位 [5] 保留。
///
/// 固件 `PasswordULFB70::VertifyPasswd(QString)` 只认长度 4；
/// `mcucom_tx_power_on_passwd()` 把 byte[4] 的 bit3/4/5/7 原样发回 MCU，
/// bit6（go into UI）只在 MCU→仪表方向使用。
Uint8List dashPowerPasswdFrame({
  int bits = 0,
  List<int> digits = const [0x30, 0x30, 0x30, 0x30],
}) {
  final b = _buf(6);
  for (var i = 0; i < 4; i++) {
    b[i] = i < digits.length ? digits[i] & 0xFF : 0x30;
  }
  b[4] = bits & 0xFF;
  b[5] = 0;
  return dashPropFrame(DashProp.powerOnPasswd, b);
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

/// indicator_lamp (16 B)：电机控制器状态位。
///
/// 默认取 [DashTelemetry.motor] 的语义状态（TCS / 档位 / 灯态 …）；
/// `lampHex` 非空时用于逐位诊断覆盖。**恒返回一帧** —— 真车电控从第一拍
/// 起就在周期上报状态，不能因为「暂时没有 icon 要显示」就整帧不发。
Uint8List dashLampFrame(DashTelemetry t) {
  var s = t.lampHex.replaceAll(' ', '');
  if (s.isEmpty) return dashPropFrame(DashProp.lampIn, t.motor.encode());
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
///
/// 包含 `indicator_lamp`：真车电机控制器按周期上报 TCS / READY / 灯态，
/// 不是「有变化才发一帧」。P 档场景是否把某个 icon 画到屏幕由固件决定，
/// 但链路这一侧必须始终有完整状态。
List<Uint8List> dashKeepFrames(DashTelemetry t) => [
  dashU32Frame(DashProp.kl15, t.kl15),
  dashU32Frame(DashProp.heartbeat, 0),
  dashLampFrame(t),
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
    McuPassword? password,
    this.onPasswordVerified,
    this.onPasswordShutdown,
    this.requirePassword = false,
    this.passwordTimeout = const Duration(seconds: 120),
    this.preArmTimeout = const Duration(seconds: 25),
  })  : telemetry = telemetry ?? DashTelemetry(),
        password = password ?? McuPassword();

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

  /// MCU 侧开机密码会话。**没有客户端界面**：数字状态只存在这里，
  /// 界面由固件 `PasswordUL` 自己画，按键同时原样透传给仪表。
  final McuPassword password;

  /// MCU 校验结果（true=通过）。控制器据此推进整车状态机。
  final void Function(bool accepted)? onPasswordVerified;

  /// 固件在原生密码页要求关机（长按 BACK / 倒计时归零）。控制器据此走
  /// 正常下电流程，**不是**普通解锁失败。
  final void Function()? onPasswordShutdown;

  /// 本次上电是否要求开机密码。
  ///
  /// 真车判定（用户 2026-11-06 确认）：只有「手把键 / MCU 唤醒」且
  /// 「手机未连接（仪表蓝牙灯灭）」时才需要密码；刷卡、App/TBOX 解锁、
  /// 蓝牙已连手机都不弹密码页。`controller.passwordAtBoot` 只是「本车
  /// 设过密码」的配置，真正是否上报 go-into-UI 由本字段决定。
  ///
  /// **必须在 pre-arm 阶段就上报**：AE5I 的 `BaseWidget::initWidget()`
  /// （libcfeasyconnect.so @0x52170）在初始化时读
  /// `mcucom_get_power_on_passwd()`，返回的 6 B 里 byte[4] bit1 置位就调
  /// `slots_password_ui(1)` 把原生 `PasswordUL` 建出来；而
  /// `mcucom_rx_power_on_passwd_handle()` 正是把 payload byte[4] 的 bit6
  /// 存成这个 bit1。界面起来之后再发就晚了。
  final bool requirePassword;

  /// 等待用户在固件原生密码页上输入的时间上限。
  final Duration passwordTimeout;

  final Duration preArmTimeout;

  static bool _false() => false;
  static void _noopLog(String _) {}
  static void _noopPhase(DashUpPhase _, String _) {}

  bool _stopped = false;
  Future<void>? _runFuture;
  DashUpPhase _phase = DashUpPhase.idle;
  int _lastRtcMinute = -1;

  /// 固件原生密码页要求关机（长按 BACK / 右上角倒计时归零）。
  ///
  /// 两条路径最终都走 `PasswordUL::shutDown()`，把 `Power_On_Passwd` 的
  /// `byte[4]` shutdown_notify（wire bit5 = 0x20）发给 MCU。倒计时本身由
  /// 固件自己跑（`MCU_SIGNAL_AUTOMATIC_SHUTDOWN` → 10 步 × 1 s），
  /// **MCU 侧不能另起一份无条件倒计时**，否则用户还在输密码就会被误关机。
  bool _passwordShutdown = false;

  /// 本次密码会话已被其他授权方式（刷卡 / App / 手机蓝牙）取消。
  /// 用于「启动途中刷卡」：状态机已撤销密码要求，feeder 不能再 begin()
  /// 干等一个永远不会来的密码。
  bool _passwordCancelled = false;

  Timer? _backLongTimer;

  /// 固件 `KeyDelegate::app_key_press_left()` 的长按判定是 3000 ms；
  /// 多留 200 ms 余量。即使固件没把 shutdown_notify 透传出来，长按 BACK
  /// 也能由 MCU 兜底关机。
  static const Duration _backLongThreshold = Duration(milliseconds: 3200);

  DashUpPhase get phase => _phase;
  bool get stopped => _stopped;

  /// 进场序列已完成的标记（供 UI 判断"画面确实亮了"）。
  bool entered = false;

  Future<void> start() => _runFuture ??= _run();

  void stop() {
    _stopped = true;
    _cancelPasswordTimers();
    _setPhase(DashUpPhase.stopped, 'MCU 对端停止');
  }

  /// 电机控制器状态变化：立刻补一拍状态帧，不等 0.5 s 心跳周期。
  ///
  /// 链路：把手按键 / 解锁 / Ready → `McuSim` → `QemuController` 同步
  /// [telemetry] 与 `telemetry.motor` → 这里立即上行 → 固件 widget 自己重画。
  /// 不写 `vehicle_info2.gear`（反复写会重摆顶部 item 造成图标重影）。
  Future<void> motorChanged() async {
    if (_stopped || !entered) return;
    await _sendAll([
      dashLampFrame(telemetry),
      dashVi1Frame(telemetry),
      dashVi3Frame(telemetry),
      dashBattFrame(telemetry),
    ]);
  }

  /// 仅在 MCU 挡位状态改变时发送，避免周期重发导致场景重绘。
  Future<void> gearChanged() async {
    if (_stopped || !entered) return;
    await _send(dashVi2Frame(telemetry, gear: telemetry.gear));
  }

  // ------------------------------------------------------------ 开机密码会话
  //
  // 真车分工（§49）：仪表 `PasswordULFB70` 负责原生界面与 4 位输入，
  // MCU 负责校验。客户端这里只发「请求进入界面」和「校验结果」两类帧，
  // 绝不绘制或镜像任何密码界面。

  /// 长按 Ready 且无 NFC/蓝牙/App 时，MCU 请求仪表进入原生密码界面。
  /// 先清一次状态位再置位：`checkUint8AndEmitSignalIntWithBit` 只在位变化时
  /// 发 `MCUCOM_SIGNAL_POWER_ON_PASSWD_GO_INTO_UI`。
  Future<void> passwordBegin() async {
    if (_stopped) return;
    if (password.active) return;
    _passwordShutdown = false;
    _passwordCancelled = false;
    if (!password.active) password.begin();
    onLog('DashUp: MCU 开启开机密码会话 → 0x21709701 bit6 请求固件原生 PasswordUL');
    await _send(dashPowerPasswdFrame());
    await _sleep(const Duration(milliseconds: 120));
    await _send(dashPowerPasswdFrame(bits: PowerOnPasswdBit.goIntoUi, digits: password.pin.codeUnits));
  }

  /// 刷卡 / 蓝牙 / App 解锁或下电时取消会话。
  ///
  /// 除了清 bit6，还要发一次 `check_passwd_success`：固件的
  /// `PasswordUL::PowerOn()` 收到它才会 `hide()` + `deleteLater()`，
  /// 否则原生密码页会一直留在 framebuffer 上。
  Future<void> passwordCancel() async {
    final hadSession = password.active;
    // 本次上电要求过密码（固件可能已经建好页）就必须发一次 dismiss，
    // 即使 MCU 会话还没 begin（例如启动途中就刷卡/连上手机）。
    if (!hadSession && !requirePassword) return;
    _passwordCancelled = true;
    password.cancel();
    _cancelPasswordTimers();
    onLog('DashUp: MCU 取消开机密码会话（其他方式已授权）');
    if (_stopped) return;
    await _send(dashPowerPasswdFrame(bits: PowerOnPasswdBit.checkSuccess));
    await _sleep(const Duration(milliseconds: 120));
    await _send(dashPowerPasswdFrame());
  }

  /// 把手按键（客户端已同时把同一 KeyID 原样透传给仪表）。
  Future<void> passwordKey(PasswordKey k) async {
    if (_stopped || _passwordShutdown) return;
    await _passwordResult(password.key(k));
  }

  /// 按键**按下**：客户端把 KeyID 原样发给固件后调这里。
  ///
  /// 长按 BACK 的判定在固件 `KeyDelegate`（3000 ms），客户端必须真实地
  /// 保持按下、直到用户松手才发抬起帧，不能再用 40 ms 的合成 tap。
  /// 这里额外起一个 MCU 侧兜底定时器：即使固件没把 shutdown_notify
  /// 透传出来，长按 BACK 也能关机。
  Future<void> passwordKeyDown(PasswordKey k) async {
    if (_stopped || _passwordShutdown) return;
    if (k != PasswordKey.back) return;
    _backLongTimer?.cancel();
    _backLongTimer = Timer(_backLongThreshold, () {
      // 密码页可能已经在 pre-arm 阶段画出来，但 `_awaitPassword()` 还没
      // begin()；只要本次上电要求密码，长按 BACK 就应能关机。
      if (_stopped || _passwordShutdown) return;
      if (!password.active && !requirePassword) return;
      onLog('DashUp: 长按 BACK ≥3.2s → MCU 关机');
      _shutdownFromPassword('长按 BACK');
    });
  }

  /// 按键**抬起**：先取消 BACK 长按定时器，再把短按语义喂给 MCU 会话
  /// （数字/光标只存在 MCU 侧，界面仍由固件绘制）。
  Future<void> passwordKeyUp(PasswordKey k, {bool feed = true}) async {
    if (k == PasswordKey.back) {
      _backLongTimer?.cancel();
      _backLongTimer = null;
    }
    if (_stopped || _passwordShutdown) return;
    if (!feed) return; // 手指滑出按键 = 只抬起，不产生短按语义
    await _passwordResult(password.key(k));
  }

  void _shutdownFromPassword(String why) {
    if (_passwordShutdown) return;
    _passwordShutdown = true;
    password.cancel();
    _cancelPasswordTimers();
    onLog('DashUp: 密码页要求关机（$why）→ 交给控制器走正常下电');
    onPasswordShutdown?.call();
  }

  void _cancelPasswordTimers() {
    _backLongTimer?.cancel();
    _backLongTimer = null;
  }

  /// 固件 `PasswordUL` 通过 `mcucom_tx_power_on_passwd` 直接提交密码时，
  /// 由控制器解析 `0x21709701` 上行帧后交给 MCU 校验。
  Future<void> passwordFromFirmware(List<int> payload) async {
    if (_stopped || _passwordShutdown) return;
    final r = password.verifyFrame(payload);
    if (r == PasswordResult.pending) return;
    onLog('DashUp: 收到固件 PasswordUL 密码结果 / 校验请求');
    await _passwordResult(r);
  }

  Future<void> _passwordResult(PasswordResult r) async {
    switch (r) {
      case PasswordResult.pending:
        return;
      case PasswordResult.accepted:
        _cancelPasswordTimers();
        await _send(dashPowerPasswdFrame(bits: PowerOnPasswdBit.checkSuccess));
        await _send(dashSyncFrame(true));
        onLog('DashUp: 收到密码通过状态 → check_passwd_success + 解锁通知');
        onPasswordVerified?.call(true);
        return;
      case PasswordResult.rejected:
        await _send(
            dashPowerPasswdFrame(bits: PowerOnPasswdBit.tryNumberError));
        await _sleep(const Duration(milliseconds: 120));
        await _send(dashPowerPasswdFrame()); // 清位，允许下次上升沿
        onLog('DashUp: MCU 校验失败（第 ${password.failures} 次）');
        onPasswordVerified?.call(false);
        return;
      case PasswordResult.shutdown:
        _shutdownFromPassword('固件 shutdown_notify');
        return;
    }
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
      if (_stopped || _passwordShutdown) return;
      await _burst(20, const Duration(milliseconds: 150), DashUpPhase.settle);
      if (_stopped) return;
      await _enter();
      if (_stopped) return;
      await _hold();
    } catch (e) {
      onLog('DashUp 异常：$e');
    }
  }

  /// ⓐ pre-arm：App 首帧之前只喂 KL15 + RTC + 密码存在位，**禁喂解锁**。
  Future<void> _preArm() async {
    _setPhase(
        DashUpPhase.preArm,
        requirePassword
            ? 'pre-arm：KL15 + RTC + 本次上电需要密码（手把键唤醒且手机未连接）'
            : 'pre-arm：KL15 + RTC 灌入（不喂解锁、不弹密码页，保证进场动画不被拆帧）');
    await _sendAll(dashBootFrames(telemetry));
    if (requirePassword) {
      await _send(dashPowerPasswdFrame(bits: PowerOnPasswdBit.goIntoUi, digits: password.pin.codeUnits));
    }
    await _sleep(const Duration(milliseconds: 250));
    final deadline = DateTime.now().add(preArmTimeout);
    while (!_stopped && DateTime.now().isBefore(deadline)) {
      await _send(dashU32Frame(DashProp.kl15, telemetry.kl15));
      await _send(dashRtcFrame(telemetry));
      if (requirePassword && !_passwordCancelled) {
        await _send(dashPowerPasswdFrame(bits: PowerOnPasswdBit.goIntoUi, digits: password.pin.codeUnits));
      }
      await _sleep(const Duration(milliseconds: 200));
      final p = paintedPct();
      // 密码页很暗（≈2.5% 非黑），门槛放低，否则会白等到超时。
      final threshold = requirePassword ? 0.01 : 0.03;
      if (p > threshold && !animating()) {
        onLog('DashUp: App 首帧已出现（非黑 ${(p * 100).toStringAsFixed(1)}%）');
        return;
      }
    }
    onLog('DashUp: pre-arm 等待超时，按既定序列继续进场');
  }

  /// ⓑ 基线重放 + ★解锁通知；设了密码就等用户在固件原生页输完。
  Future<void> _bootUnlock() async {
    _setPhase(DashUpPhase.boot, '重放上电基线（版本/握手/能力/状态/KL15）');
    await _sendAll(dashBootFrames(telemetry));
    await _sleep(const Duration(milliseconds: 350));
    if (requirePassword) {
      await _awaitPassword();
      if (_stopped || _passwordShutdown) return;
      // ★ 密码通过后才允许播开机动画：控制器在 passwordVerified 时创建
      //   wake 文件，模型开始重放原厂 logo。这里等 logo 播完再继续
      //   settle/enter，避免固件的 P 档进场动画被 logo 盖住白播。
    }
    await _awaitBootAnim();
    if (_stopped || _passwordShutdown) return;
    _setPhase(DashUpPhase.unlock,
        '喂 synchronization_status 解锁通知（放行 slot_delayUpdateGear）');
    await _send(dashSyncFrame(true));
    await _sleep(const Duration(milliseconds: 350));
  }

  /// 已设置密码：等固件 `PasswordUL` 把 4 位密码提交上来，校验通过后
  /// `_passwordResult` 会发 check_passwd_success + 解锁通知。
  Future<void> _awaitPassword() async {
    if (_passwordCancelled) {
      // 启动途中已刷卡 / App / 手机授权，状态机撤销了密码要求。
      onLog('DashUp: 密码要求已被其他授权方式取消，跳过等待');
      return;
    }
    _setPhase(DashUpPhase.unlock,
        '已上报「本次上电需要密码」→ 固件显示原生密码解锁页，等待输入 4 位密码');
    if (!password.active) password.begin();
    _passwordShutdown = false;
    final deadline = DateTime.now().add(passwordTimeout);
    while (!_stopped &&
        !_passwordShutdown &&
        DateTime.now().isBefore(deadline)) {
      if (!password.active) {
        onLog('DashUp: 密码校验通过，继续点亮仪表');
        return;
      }
      await _send(dashU32Frame(DashProp.kl15, telemetry.kl15));
      await _send(dashPowerPasswdFrame(bits: PowerOnPasswdBit.goIntoUi, digits: password.pin.codeUnits));
      await _sleep(const Duration(milliseconds: 500));
    }
    if (_passwordShutdown) return;
    if (password.active) {
      // 超时不能「按未验证继续」——那等于绕过密码直接点亮。
      // 真车没有输入正确密码就不会进主界面，这里按 MCU 超时下电处理。
      onLog('DashUp: 等待密码超时 → MCU 关机（不允许跳过密码）');
      _shutdownFromPassword('等待密码超时');
    }
  }

  /// 密码通过后等原厂开机 logo 播完。
  ///
  /// 模型是「客户端创建 wake 文件 → 重放 anm_logo.bin → BOOTANIM: guest took」。
  /// 先等它真正开始（最多 3 s），再等它交还 guest（最多 15 s）；没有配置
  /// 开机动画时 animating 恒为 false，最多多等 3 s。
  Future<void> _awaitBootAnim() async {
    final startWait = DateTime.now();
    while (!_stopped &&
        !_passwordShutdown &&
        !animating() &&
        DateTime.now().difference(startWait) < const Duration(seconds: 3)) {
      await _sleep(const Duration(milliseconds: 50));
    }
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (!_stopped &&
        !_passwordShutdown &&
        animating() &&
        DateTime.now().isBefore(deadline)) {
      await _sleep(const Duration(milliseconds: 50));
    }
    if (!_stopped && !_passwordShutdown) {
      onLog('DashUp: 开机 logo 已播完，继续 P 档进场序列');
    }
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
    final enteredGear = telemetry.gear;
    _setPhase(DashUpPhase.enter,
        '只写一次 gear=$enteredGear，触发仪表进场动画');
    await _send(dashVi2Frame(telemetry, gear: enteredGear));
    await _send(dashRtcFrame(telemetry));
    await _sleep(const Duration(milliseconds: 400));
    // 电控状态必须等进场动画跑完再喂（提前喂会让 App 重建场景，把
    // "骑行获得数据~" 占位文字压在真值下面）。动画结束后第一拍就把
    // TCS / READY / 驻车 / 灯态全量上报，此后由 heart beat 持续维持。
    await _sleep(const Duration(milliseconds: 2500));
    await _send(dashLampFrame(telemetry));
    await _sleep(const Duration(milliseconds: 600));
    entered = true;
    if (telemetry.gear != enteredGear) await gearChanged();
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
