// GD32 MCU 的 CFCP 对端。本项目里 **客户端扮演 MCU**，QEMU 里的 guest 是 SoC。
//
// ── 这条通道到底是什么（2026-11-02 实测 + 真机固件反汇编结论）────────────
// 真车链路：SoC(Launcher/Qt) ⇄ ttyS1(CFCP) ⇄ GD32 MCU。
//
// 实测结论（全部可复现，见 test/sub_probe.dart / test/key_effect.dart /
// test/cfcp_upstream.dart）：
//   ① **属性通道是双向镜像的**：我们写进 ttyS1 的属性值，guest 会原样再广播
//      回来（发版本串 'SW.1.00.56 AE5I' → guest 广播 prop=0x21701002 同串；
//      发握手=1 → 广播 0x21417310=1；心跳 0 → 每秒广播 0x21709521=0）。
//      **去掉这些基线帧，guest 的属性表就空、什么都不广播**（已实测）。
//   ② guest 同时广播**我们从没发过**的值：灯态位图 6/7/13/18/19/30/38/−24/
///      −28/−33/−35、档位 8/9/10 ⇒ 那是集群自己的状态，我们只能观测。
//   ③ **但我们写入属性不会改变集群渲染**：11 个候选属性 × sub 0..4 共 55 组
//      全扫，framebuffer 变化恒为 0，guest 也不回播我们的值。
//      ⇒ 主表盘**不由这条属性通道驱动**，这是 §23.4 遗留问题的确证。
//   ④ 面板键（CFCP KeyID 0xd2/0xd3/0xd4/0xd5）**会**改变 guest 自己的灯态
//      位图（实测：按下键 6→38，Δ=0x20 即 bit5）⇒ 集群状态机是活的、能响应按键。
//   ⑤ MCU 车身键（转向/双闪/远光…）在真车上由 GD32 执行，**不经仪表**；要让
//      集群的指示灯点亮，必须把车辆信号**上行**（MCU→SoC）喂给集群，
//      而这条上行帧格式尚未解出（见下）。
//
// ── 上行（MCU→SoC）待解的那一环 ───────────────────────────────────────
// 真机 `libmcucommodule.so` 的接收侧槽函数已定位：
//   mcucom_rx_ride_info_update(u8,u8,u8,u8*,u16) @0x397c4
//       → 载荷是**大端 u16 TLV 标签 0xCF01/0xCF02…**，每条记录 35 B
//         （2 B 标签 + 33 B 负载），子类型参数 3/4 决定写入 this+0x270 / this+0x2c8。
//   mcucom_rx_ride_info_status_handle(RIDE_INFO_TYPE, u8) @0x283a1
//   mcucom_rx_indicator_lamp_handle(vector<u8>) @0x3b390  ← 指示灯（8532 B，最大）
//   mcucom_rx_vehicle_info1/2/3_handle(vector<u8>)
//   mcucom_rx_KL15_STATE_handle(int) @0x300a4        ← 点火/整车就绪
//   mcucom_rx_cruise_shock_level_handle / mcucom_rx_trip_1 / trip_2 / trip_total_ODO
// 上游车辆数据的属性/命令路由与 Launcher 实际消费尚未闭环；不能把 ACK、
// 缓存命中或单个 handler 的存在当作渲染数据已送达。主表盘的渲染阻塞点仍待定位。
//
// ── 帧格式 ────────────────────────────────────────────────────────────────
// `fe5aaaa5` + `11 02 75 01 01 00` + len u16LE(=inner+2) + inner u16LE
//   + prop u32LE + sub u32LE + 值(int32 / 2 字节 LE / 定长 ASCII)
//   + `~sum(bytes[4..chk])` + `a5555a`
// 校验与取值宽度已用真机抓包逐字节校验（见 cfcp.dart 的 cfcpPropFrame 注释）。
//
// ── 属性 id 出处 ─────────────────────────────────────────────────────────
// 真机 `libmcucommodule.so`（`/tmp/ae5i_spapp/root/lib/module/default/`）里
// 共 60 个 0x21/0x27 家族 id，按所在函数可分成两类：
//   * SoC 侧下行命令：`mcucom_set_*` / `mcucom_tx_*`
//     （setItem1-4、ABS/MTC/ESS/AUTO_HEADLIGHT、DRIVEMODE、单位、主题、
//      BT/WiFi/BLE 地址、胎压胎温、OTA URL、声音特效、天气、FBL 服务…）
//   * 集群状态广播：握手、SW 版本、心跳、能力掩码、状态字节、灯态、档位、胎压。
// 反汇编得到的拥有者（节选）：
//   0x21407072 → MCUCOMModule::peridic_task()           灯态，周期广播
//   0x21709702 → MCUCOMModule::mcucom_set_system_send() 档位，2 字节
//   0x21709521 → MCUCOMModule::mcucom_tx_DownLinkData() 心跳
//   0x21701002 → MCUCOMModule::internal_set_SWVersion() SW 版本串
//   0x21407065..71 → mcucom_set_trip1_clean/trip2_clean/brighness_adj/
//                    spd_unit/tmp_unit/car_theme/resetMaintanceODO
//   0x21409308/09 → mcucom_set_ABS / mcucom_set_MTC
//   0x21709301..03 → mcucom_tx_setItem1/2/3
//   0x21707073 → mcucom_tx_setItem4
//   0x27407404 → mcucom_ble_tire_pressure
//   0x27400027 → mcucom_ble_tire_temp
//
// ── 灯态取值（重要更正）──────────────────────────────────────────────────
// 旧笔记写「0x21407072 取 0x03/0x0c/0x18/0x16 = 左/右/双闪/远光」——**这是错的**，
// 那是从宿主固件副本猜的。实测 guest 广播的灯态值是**位图**：
//   6, 7, 13, 18, 19, 30, 38, −24, −28, −33, −35
// 其中唯一能归因的一次跃迁是「按下键」→ 6 变 38（Δ=0x20，即 bit5）。
// 其余 bit 对应哪盏灯尚未逐位确认，所以本文件不再臆造映射：
// `McuState` 只保留**语义**（左转/右转/双闪/远光…），
// 线上取值交给 `lampMaskFromState()`，其中未确认的位默认 0。

library;

import 'dart:typed_data';

import 'cfcp.dart';
import 'mcu.dart';

/// 真机 CFCP 属性 id（32 位，来自 `libmcucommodule.so`）。
class CfcpProp {
  CfcpProp._();

  // ── guest（SoC）广播给我们、我们应当**接收**的属性 ──────────────────

  /// 握手/就绪。guest 广播恒为 1。
  static const int handshake = 0x21417310;

  /// SoC 侧软件版本串（24 字节定长 ASCII）。
  static const int swVersion = 0x21701002;

  /// 心跳，guest 每秒广播一次，值 0。
  static const int heartbeat = 0x21709521;

  /// 能力/掩码，guest 广播 0xffffffff。
  static const int capability = 0x27407404;

  /// 车辆状态字节。guest 广播为 6 字节负载。
  static const int status = 0x21707701;

  /// **灯态位图**。guest 广播，实测值 6/7/13/18/19/30/38/−24/−28/−33/−35。
  /// 位含义待逐位确认；下行写入集群不认（见文件头）。
  static const int lampMask = 0x21407072;

  /// **档位**，2 字节小端。guest 广播 8/9/10。
  static const int gear = 0x21709702;

  /// 胎温（BLE 胎压监测模块）。
  static const int tireTemp = 0x27400027;

  /// 胎压丢失标志。
  static const int tireLost = 0x27410028;

  /// OTA 二维码 URL（字符串属性）。
  static const int otaQrUrl = 0x21709510;

  // ── 我们（MCU）下发给 guest 的命令 ──────────────────────────────────
  // 真实 MCU 收到的是这些命令的执行结果；下行方向本项目暂不主动发，
  // 保留 id 便于将来对齐 setItem1-4（自定义键功能码 7 就走 setItem4）。

  /// `mcucom_tx_setItem1`。
  static const int setItem1 = 0x21709301;

  /// `mcucom_tx_setItem2`。
  static const int setItem2 = 0x21709302;

  /// `mcucom_tx_setItem3`。
  static const int setItem3 = 0x21709303;

  /// `mcucom_tx_setItem4`（自定义键切信息组的功能码 7 走这条）。
  static const int setItem4 = 0x21707073;

  /// `mcucom_set_DRIVEMODE`。
  static const int driveMode = 0x2140003b;

  /// `mcucom_set_lanuage`。
  static const int language = 0x21400008;

  /// `mcucom_set_spd_unit`。
  static const int speedUnit = 0x21407068;

  /// `mcucom_set_tmp_unit`。
  static const int tempUnit = 0x21407069;

  /// `mcucom_set_car_theme`。
  static const int carTheme = 0x21407070;

  /// `mcucom_set_ABS`。
  static const int abs = 0x21409308;

  /// `mcucom_set_MTC`。
  static const int mtc = 0x21409309;

  /// `mcucom_set_ESS`。
  static const int ess = 0x21409505;

  /// `mcucom_set_AUTO_HEADLIGHT`。
  static const int autoHeadlight = 0x21409305;
}

/// guest 会主动广播的属性集合（我们作为 MCU 应收这些）。
const Set<int> kGuestPublishedProps = {
  CfcpProp.handshake,
  CfcpProp.swVersion,
  CfcpProp.heartbeat,
  CfcpProp.capability,
  CfcpProp.status,
  CfcpProp.lampMask,
  CfcpProp.gear,
  CfcpProp.tireTemp,
  CfcpProp.tireLost,
  CfcpProp.otaQrUrl,
};

/// 旧 id 保留别名，避免其它代码引用报错；**不要再用**（见文件头更正说明）。
class CfcpPropLegacy {
  CfcpPropLegacy._();

  /// 旧的（错误）灯态 id 命名，实质就是 [CfcpProp.lampMask]。
  static const int lampStatus = CfcpProp.lampMask;

  /// 旧的（错误）档位 id 命名，实质就是 [CfcpProp.gear]。
  static const int gearLegacy = CfcpProp.gear;
}

/// 把车身语义状态编成灯态位图。
///
/// ⚠ 位含义**尚未逐位确认**（见文件头）。当前只有 bit5 有实测归因
/// （按下键使灯态 6→38）。因此除已确认位外一律置 0，避免臆造。
/// 宁可少点亮，也不要点亮错误的灯——后者会掩盖真实问题。
int lampMaskFromState(McuState s) {
  var mask = 0;
  // 实测：按下（面板下键）后 guest 广播灯态由 6 变 38，Δ=0x20 ⇒ bit5。
  // 该位与「面板当前项」相关，暂不由车身状态驱动，留 0。
  if (s.hazard) {
    // 双闪：位未确认，先不置位。
  }
  return mask;
}

/// 一次上电/解锁后 **MCU 侧**发给仪表的基线帧序列。
///
/// ⚠ 语义更正（2026-11-02，实测）：这条属性通道是**双向镜像**的 ——
///   * 我们写进去的值，guest 会原样再广播一遍（实测：发版本串
///     'SW.1.00.56 AE5I' → guest 广播 prop=0x21701002 同串；发握手=1 → guest
///     广播 0x21417310=1；心跳 0 → guest 每秒广播 0x21709521=0）。
///     **去掉这些帧，guest 的属性表就是空的、什么都不广播**（实测 2026-11-02）。
///     所以它们是「链路基线」，必须保留。
///   * guest 同时会广播**我们从没发过**的值：灯态位图 6/7/13/18/19/30/38/
///     −24/−28/−33/−35、档位 8/9/10 ⇒ 那是集群自己的状态。
///   * 但**我们写入这些属性不会改变集群渲染**：11 个候选属性 × sub 0..4 共
///     55 组全扫，framebuffer 变化恒为 0（test/sub_probe.dart）。
///     ⇒ 主表盘不由这条通道驱动，见 EMULATION.md §29。
List<Uint8List> gd32BootFrames({String version = 'SW.1.00.56 AE5I'}) => [
  // MCU 版本（真机样本帧）
  cfcpPropFrame(CfcpProp.swVersion, 0, strValue: version, strLen: 24),
  // 握手/就绪
  cfcpPropFrame(CfcpProp.handshake, 0, intValue: 1),
  // 能力掩码
  cfcpPropFrame(CfcpProp.capability, 0, intValue: 0xffffffff),
  // 状态字节
  cfcpPropFrame(CfcpProp.status, 0, intValue: 0xc0),
  // 属性基线样本（2 字节小端）。guest 会镜像回传；语义不用于渲染推断。
  cfcpPropFrame(CfcpProp.gear, 0, rawValue: [8, 0]),
  // 心跳
  cfcpPropFrame(CfcpProp.heartbeat, 0, intValue: 0),
  // 灯态（全灭；位含义待逐位确认）
  cfcpPropFrame(CfcpProp.lampMask, 0, intValue: 0),
];

/// 车身状态变化时发给仪表的帧。
///
/// 目前只发灯态位图。⚠ 集群**不消费**我们写的灯态（实测 0 px），真正驱动转向/
/// 双闪/远光指示灯的是 MCU→SoC 上行车辆信号帧，其格式尚未解出
/// （EMULATION.md §29 已定位到 `mcucom_rx_indicator_lamp_handle` @0x3b390 与
/// `mcucom_rx_ride_info_update` @0x397c4 的 BE u16 TLV 标签 0xCF01..0xCF0B）。
List<Uint8List> gd32StateFrames(McuState s) => [
  cfcpPropFrame(CfcpProp.lampMask, 0, intValue: lampMaskFromState(s)),
];

/// 周期心跳（1 Hz，与真机一致）。
Uint8List gd32HeartbeatFrame() =>
  cfcpPropFrame(CfcpProp.heartbeat, 0, intValue: 0);

/// 人类可读的一行摘要，供日志显示「发了哪一帧、值是多少」。
String describeFrame(Uint8List f) {
  // 最小合法帧 = 26 B（空负载）；2 字节负载 28 B、4 字节负载 30 B。
  if (f.length < 26) return 'CFCP 属性帧(${f.length}B, 过短)';
  final v = ByteData.sublistView(f);
  final prop = v.getUint32(14, Endian.little);
  final sub = v.getUint32(18, Endian.little);
  final inner = v.getUint16(12, Endian.little);
  final valueLen = inner - 8; // inner = prop(4) + sub(4) + value
  if (valueLen > 0 && valueLen <= 4) {
    var val = 0;
    for (var i = 0; i < valueLen; i++) {
      val |= f[22 + i] << (8 * i);
    }
    return 'CFCP prop=0x${prop.toRadixString(16)} sub=$sub int=$val (${valueLen}B)';
  }
  final bytes = f.sublist(22, 22 + valueLen);
  final text = String.fromCharCodes(bytes.takeWhile((b) => b != 0));
  return 'CFCP prop=0x${prop.toRadixString(16)} sub=$sub str="$text"';
}

/// guest 广播给我们的属性 → 人类可读摘要（用于日志/UI）。
String describePeerProp(int prop, int value) {
  switch (prop) {
    case CfcpProp.handshake:
      return '握手=$value';
    case CfcpProp.swVersion:
      return 'SW 版本';
    case CfcpProp.heartbeat:
      return '心跳';
    case CfcpProp.capability:
      return '能力掩码=0x${value.toRadixString(16)}';
    case CfcpProp.status:
      return '车辆状态=0x${value.toRadixString(16)}';
    case CfcpProp.lampMask:
      return '灯态位图=0x${value.toRadixString(16)}($value)';
    case CfcpProp.gear:
      return '档位=$value';
    case CfcpProp.tireTemp:
      return '胎温标志=0x${value.toRadixString(16)}';
    case CfcpProp.tireLost:
      return '胎压丢失=0x${value.toRadixString(16)}';
    default:
      return 'prop=0x${prop.toRadixString(16)}=$value';
  }
}

/// guest（SoC）广播给我们的**仪表状态快照**。
///
/// 这是目前观察集群真实状态唯一可靠的窗口：guest 自己把灯态位图、档位、
/// 车辆状态、心跳等属性帧发到 ttyS1，我们作为 MCU 侧接收并解析。
/// 真车 MCU 就是靠这些去驱动车身执行（点灯/鸣笛/切档）。
///
/// ⚠ 灯态位图的 bit→灯 映射尚未逐位确认（见文件头），所以这里保留**原始位图**
/// 而不解释成「左转/右转」。
class ClusterPeerState {
  const ClusterPeerState({
    this.lampMask,
    this.gear,
    this.status,
    this.handshake,
    this.swVersion,
    this.heartbeatCount = 0,
    this.tireTemp,
    this.tireLost,
    this.updatedAt,
  });

  /// 0x21407072 灯态位图（原始值）。
  final int? lampMask;

  /// 0x21709702 档位（2 字节，8/9/10）。
  final int? gear;

  /// 0x21707701 车辆状态字节。
  final int? status;

  /// 0x21417310 握手/就绪（guest 恒为 1）。
  final int? handshake;

  /// 0x21701002 SoC 软件版本串。
  final String? swVersion;

  /// 收到的 0x21709521 心跳次数（guest 约 1 Hz）。
  final int heartbeatCount;

  /// 0x27400027 胎温标志。
  final int? tireTemp;

  /// 0x27410028 胎压丢失标志。
  final int? tireLost;

  /// 最近一次更新的时刻。
  final DateTime? updatedAt;

  /// guest 侧 MCU 通信模块是否已握手（SoC 认为 MCU 在线）。
  bool get mcuLinkUp => handshake != null && handshake != 0;

  /// 灯态位图的 5 位（实测唯一可归因的位：按下键 6→38）。
  int get lampBit5 => (lampMask != null && lampMask! & 0x20 != 0) ? 1 : 0;

  ClusterPeerState copyWith({
    int? lampMask,
    int? gear,
    int? status,
    int? handshake,
    String? swVersion,
    int? heartbeatCount,
    int? tireTemp,
    int? tireLost,
    DateTime? updatedAt,
  }) {
    return ClusterPeerState(
      lampMask: lampMask ?? this.lampMask,
      gear: gear ?? this.gear,
      status: status ?? this.status,
      handshake: handshake ?? this.handshake,
      swVersion: swVersion ?? this.swVersion,
      heartbeatCount: heartbeatCount ?? this.heartbeatCount,
      tireTemp: tireTemp ?? this.tireTemp,
      tireLost: tireLost ?? this.tireLost,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  @override
  String toString() {
    final parts = <String>[];
    if (lampMask != null) parts.add('灯态=0x${lampMask!.toRadixString(16)}');
    if (gear != null) parts.add('档位=$gear');
    if (status != null) parts.add('状态=0x${status!.toRadixString(16)}');
    if (swVersion != null) parts.add('SW=$swVersion');
    parts.add('心跳×$heartbeatCount');
    if (mcuLinkUp) parts.add('MCU 链路已握手');
    return parts.join('  ');
  }
}
