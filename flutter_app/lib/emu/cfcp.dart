import 'dart:typed_data';

/// AE5I CFCP key report: kernel expects 1 for press and 3 for release.
Uint8List cfcpKeyFrame(int keyId, bool pressed) {
  if (keyId < 0 || keyId > 0xffffffff) {
    throw RangeError.range(keyId, 0, 0xffffffff, 'keyId');
  }
  final bytes = Uint8List(24);
  bytes.setRange(0, 12, const [
    0xfe,
    0x5a,
    0xaa,
    0xa5,
    0x10,
    0x00,
    0x03,
    0x01,
    0x01,
    0x00,
    0x08,
    0x00,
  ]);
  final view = ByteData.sublistView(bytes);
  view.setUint32(12, keyId, Endian.little);
  view.setUint32(16, pressed ? 1 : 3, Endian.little);
  var sum = 0;
  for (var i = 4; i < 20; i++) {
    sum += bytes[i];
  }
  bytes[20] = (~sum) & 0xff;
  bytes.setRange(21, 24, const [0xa5, 0x55, 0x5a]);
  return bytes;
}

// ---------------------------------------------------------------- 帧类型

/// 帧类型：按键事件（SoC→MCU），命令字 0x03。
const int kCfcpTypeKey = 0x10;

/// 帧类型：属性读写（双向），命令字 0x75。
const int kCfcpTypeProp = 0x11;

/// 帧类型：应答——对端收到一帧后回的空负载帧。
const int kCfcpTypeAck = 0x90;

// ---------------------------------------------------------------- 帧布局
//
// 2026-11-02 用 CFCP 内核模块（`firmware/spsdk-root/drivers/rcar-taurus-cfcp.ko`，
// 与 guest 里跑的驱动同源）的**字段描述符表**解出，逐字节与真机抓包核对过。
//
// 描述符表在 `.data` 偏移 0x130，8 条、每条 20 字节，`+0xc` 是字段长度，
// `+0x10` 是字段在帧内的**偏移**；`+0xa0` 处是 header 字节、`+0xa4` 处是 tail 字节：
//
// | 字段     | 偏移   | 长度 | 实测值 / 含义                                   |
// |----------|--------|------|------------------------------------------------|
// | Header   | 0x00   | 4    | `fe 5a aa a5`（可配置，见 check_Header）        |
// | FRAME0   | 0x04   | 1    | `0x11`；bit7=is_response，bit6..4=type(1..4)，bit3..1 必须为 0 |
// | FRAME1   | 0x05   | 1    | `0x02`（属性帧）/ `0x08`（ACK）；驱动侧不校验    |
// | 命令字   | 0x06   | 4    | `75 01 01 00`（属性）/ `55 01 01 00`（ACK）     |
// | 数据长度 | 0x0a   | 2    | u16 LE，= DATA 字节数                           |
// | DATA     | 0x0c   | n    | 载荷                                            |
// | CHECKSUM | 0x0c+n | 1    | `~sum(帧内自 FRAME0 起至 DATA 末尾) & 0xff`     |
// | TAIL     | +1     | 3    | `a5 55 5a`（可配置，见 check_Tail）             |
//
// 驱动侧校验（反汇编）：
//   * `check_FRAME0`：(b>>4)&7 ∈ 1..4 且 b&0x0e == 0；
//   * `check_LEN`  ：签 16 位读、必须 < 0x200(=512)；
//   * `check_CMD`  ：(b>>4)&6 == 0（bit6/bit5 必须为 0）；
//   * `calc_checksum` / `check_CheckSum`：求和取反，见上；
//   * `dispatch_one_frame`：`is_response=1` → 走 ACK 清理（`cfcp_queue_ack_clean`）；
//     `=0` → 需要 ACK 就回 ACK，再 `cfcp_dispatch_q_frame` 投递给用户态。
//
// 头部位布局（`get_Direction` / `get_field_type` / `get_field_ACK`）：
//   bit7 = 方向/响应，bit6..4 = 字段类型，bit3..0 = ACK 模式。

/// 一条 CFCP 帧的逻辑字段（解析结果）。
class CfcpFrame {
  CfcpFrame({
    required this.frame0,
    required this.frame1,
    required this.cmd,
    required this.data,
  });

  /// 帧控制字节 0：bit7=is_response，bit6..4=type，bit3..0=ACK 模式。
  final int frame0;

  /// 帧控制字节 1。
  final int frame1;

  /// 4 字节命令字（小端存储，首字节为命令 id）。
  final int cmd;

  /// 载荷。
  final List<int> data;

  bool get isResponse => (frame0 >> 7) & 1 == 1;
  int get frameType => (frame0 >> 4) & 7;
  int get ackMode => frame0 & 0xf;

  @override
  String toString() => 'CFCP frame0=0x${frame0.toRadixString(16)} '
      'frame1=0x${frame1.toRadixString(16)} '
      'cmd=0x${cmd.toRadixString(16)} data=${data.length}B';
}

/// 通用组帧：按验证过的字段布局拼一帧。
///
/// `cmd` 是 4 字节命令字（低字节先写）。
/// 校验覆盖 `[4, chk)`，即从 FRAME0 到 DATA 末尾。
Uint8List cfcpBuildFrame({
  int frame0 = kCfcpTypeProp,
  int frame1 = 0x02,
  int cmd = 0x00010175,
  List<int> data = const [],
}) {
  if (data.length > 512) {
    throw ArgumentError('CFCP DATA 最多 512 字节（描述符表 len=512）');
  }
  final total = 4 + 1 + 1 + 4 + 2 + data.length + 1 + 3;
  final bytes = Uint8List(total);
  bytes.setRange(0, 4, const [0xfe, 0x5a, 0xaa, 0xa5]);
  bytes[4] = frame0 & 0xff;
  bytes[5] = frame1 & 0xff;
  final view = ByteData.sublistView(bytes);
  view.setUint32(6, cmd, Endian.little);
  view.setUint16(10, data.length, Endian.little);
  bytes.setRange(12, 12 + data.length, data);
  final chk = 12 + data.length;
  var sum = 0;
  for (var i = 4; i < chk; i++) {
    sum += bytes[i];
  }
  bytes[chk] = (~sum) & 0xff;
  bytes.setRange(chk + 1, total, const [0xa5, 0x55, 0x5a]);
  return bytes;
}

/// 解析一条 CFCP 帧（长度/尾/校验不成立时返回 null）。
CfcpFrame? cfcpParseFrame(List<int> f) {
  if (f.length < 16) return null;
  if (f[0] != 0xfe || f[1] != 0x5a || f[2] != 0xaa || f[3] != 0xa5) return null;
  final view = ByteData.sublistView(Uint8List.fromList(f));
  final dataLen = view.getUint16(10, Endian.little);
  final total = 12 + dataLen + 1 + 3;
  if (total > f.length) return null;
  return CfcpFrame(
    frame0: f[4],
    frame1: f[5],
    cmd: view.getUint32(6, Endian.little),
    data: f.sublist(12, 12 + dataLen),
  );
}

/// 通用 CFCP 帧封装（无嵌套长度字段的帧：键帧、ACK 帧）。
///
/// ```
/// [0..4)   fe 5a aa a5   魔术字
/// [4..7)   type b5 b6    键帧 10 00 03 / 属性 11 02 75 / ACK 90 08 55
/// [7..10)  01 01 00      版本/方向常量
/// [10..12) len   u16 LE  负载长度
/// [12..)   payload
/// [chk]    ~sum(bytes[4..chk]) & 0xff
/// [tail]   a5 55 5a
/// ```
Uint8List cfcpFrame(int type, int b5, int b6, List<int> payload) {
  final total = 4 + 3 + 3 + 2 + payload.length + 1 + 3;
  final bytes = Uint8List(total);
  bytes.setRange(0, 10, [
    0xfe, 0x5a, 0xaa, 0xa5, type, b5, b6, 0x01, 0x01, 0x00,
  ]);
  final view = ByteData.sublistView(bytes);
  view.setUint16(10, payload.length, Endian.little);
  bytes.setRange(12, 12 + payload.length, payload);
  final chk = 12 + payload.length;
  var sum = 0;
  for (var i = 4; i < chk; i++) {
    sum += bytes[i];
  }
  bytes[chk] = (~sum) & 0xff;
  bytes.setRange(chk + 1, total, const [0xa5, 0x55, 0x5a]);
  return bytes;
}

/// CFCP ACK 帧（type=0x90，空负载）。
///
/// 这是从真机 QEMU 会话里抓到的**对端（guest 内核 CFCP 驱动）回给 MCU 的应答帧**：
///
/// ```
/// fe 5a aa a5 | 90 08 55 | 01 01 00 | 00 00 | 10 | a5 55 5a     (16 B)
/// ```
///
/// 证据：一次会话里 guest 回了 23 个，恰好等于客户端发出的帧数（7 基线 + ~15 心跳），
/// 且 23 个**字节完全相同**（不随被应答帧的 cmdid/prop 变化）。
///
/// 反向验证过：客户端只发不回时，guest 内核打
/// `[CFCP] cfcp_ack_q_work_handl.L131 resend_times is 3,del list:cmdid:0x75`
/// —— 它发的 0x75 属性帧等不到 ACK，重传 3 次后丢弃，应用层拿不到属性。
///
/// 校验与其它帧同规则：`~sum(bytes[4..chk]) & 0xff`。
Uint8List cfcpAckFrame() => cfcpFrame(kCfcpTypeAck, 0x08, 0x55, const []);

/// 一条解析出来的属性帧内容。
class CfcpPropMessage {
  CfcpPropMessage(this.prop, this.sub, this.value);
  final int prop;
  final int sub;
  final List<int> value;

  /// 4 字节负载 → int32（多数信号是这个宽度）。
  int? get asInt =>
      value.length == 4 ? ByteData.sublistView(Uint8List.fromList(value)).getInt32(0, Endian.little) : null;

  /// 2 字节负载 → uint16（`0x21709702` 这类就是 2 字节）。
  int? get asU16 =>
      value.length == 2 ? ByteData.sublistView(Uint8List.fromList(value)).getUint16(0, Endian.little) : null;

  /// 变长负载 → ASCII（版本串等）。
  String get asText => String.fromCharCodes(value.takeWhile((b) => b != 0));

  @override
  String toString() {
    final v = asInt?.toString() ?? asU16?.toString() ?? asText;
    return 'prop=0x${prop.toRadixString(16).padLeft(8, '0')} sub=$sub '
        'value=$v (${value.length}B)';
  }
}

/// 解析一条属性帧（type=0x11，命令字 0x75）。不是属性帧或长度不自洽时返回 null。
CfcpPropMessage? cfcpParseProp(List<int> f) {
  if (f.length < 26 || f[4] != kCfcpTypeProp) return null;
  final v = ByteData.sublistView(Uint8List.fromList(f));
  final inner = v.getUint16(12, Endian.little);
  final valueLen = inner - 8;
  if (valueLen < 0 || 22 + valueLen > f.length - 4) return null;
  return CfcpPropMessage(
    v.getUint32(14, Endian.little),
    v.getUint32(18, Endian.little),
    f.sublist(22, 22 + valueLen),
  );
}

/// MCU→SoC 属性上报帧（CFCP 属性帧，type=0x11）。
///
/// 布局来自真机抓包逐字节反推，并用恢复到的真实帧做了校验：
///
/// ```
/// [0..4)   fe 5a aa a5            魔术字
/// [4..10)  11 02 75 01 01 00      属性帧头（键帧是 10 00 03 01 01 00）
/// [10..12) len   u16 LE           = inner + 2（负载总长）
/// [12..14) inner u16 LE           = 4(prop) + 4(sub) + valueLen
/// [14..18) prop  u32 LE           属性 id
/// [18..22) sub   u32 LE           子索引（多数为 0）
/// [22..)   value                   int32 LE，或定长 ASCII 字符串（尾部补 0）
/// [chk]    ~sum(bytes[4..chk])&0xff
/// [tail]   a5 55 5a
/// ```
///
/// 真机样本（用于回归校验）：
/// - `fe5aaaa5 110275 010100 0e00 0c00 10734121 00000000 01000000 75 a5555a`
///   即 prop=0x21417310, sub=0, value=1, 共 30 字节。
/// - `fe5aaaa5 110275 010100 2200 2000 02107021 00000000 "SW.1.00.56 AE5I"… 3c a5555a`
///   即 prop=0x21701002 的 24 字节版本串。
Uint8List cfcpPropFrame(
  int propId,
  int sub, {
  int? intValue,
  String? strValue,
  List<int>? rawValue,
  int strLen = 0,
}) {
  final given =
      [intValue != null, strValue != null, rawValue != null].where((e) => e).length;
  if (given > 1) {
    throw ArgumentError('intValue / strValue / rawValue 只能给一个');
  }
  final List<int> value;
  if (rawValue != null) {
    value = rawValue;
  } else if (strValue != null) {
    final n = strLen > 0 ? strLen : ((strValue.length + 1 + 3) & ~3);
    final buf = List<int>.filled(n, 0);
    final raw = strValue.codeUnits;
    for (var i = 0; i < raw.length && i < n; i++) {
      buf[i] = raw[i] & 0xff;
    }
    value = buf;
  } else {
    final v = intValue ?? 0;
    value = [
      v & 0xff,
      (v >> 8) & 0xff,
      (v >> 16) & 0xff,
      (v >> 24) & 0xff,
    ];
  }
  final inner = 4 + 4 + value.length;
  final len = inner + 2;
  // magic(4) + 属性帧头(6) + len(2) + inner(2) + 负载(inner) + 校验(1) + 尾(3)
  final total = 4 + 6 + 2 + 2 + inner + 1 + 3;
  final bytes = Uint8List(total);
  bytes.setRange(0, 10, const [
    0xfe, 0x5a, 0xaa, 0xa5, // magic
    0x11, 0x02, 0x75, // 属性帧
    0x01, 0x01, 0x00, // 版本/方向常量（真机固定）
  ]);
  final view = ByteData.sublistView(bytes);
  view.setUint16(10, len, Endian.little);
  view.setUint16(12, inner, Endian.little);
  view.setUint32(14, propId, Endian.little);
  view.setUint32(18, sub, Endian.little);
  bytes.setRange(22, 22 + value.length, value);
  final chkIndex = total - 4;
  var sum = 0;
  for (var i = 4; i < chkIndex; i++) {
    sum += bytes[i];
  }
  bytes[chkIndex] = (~sum) & 0xff;
  bytes.setRange(chkIndex + 1, total, const [0xa5, 0x55, 0x5a]);
  return bytes;
}
