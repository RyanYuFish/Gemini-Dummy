import 'dart:typed_data';

import 'package:ae5i_emu/emu/cfcp.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('AE5I key report emits the verified press and release values', () {
    final press = cfcpKeyFrame(0x67, true);
    final release = cfcpKeyFrame(0x67, false);
    expect(press, [
      0xfe,
      0x5a,
      0xaa,
      0xa5,
      0x10,
      0,
      3,
      1,
      1,
      0,
      8,
      0,
      0x67,
      0,
      0,
      0,
      1,
      0,
      0,
      0,
      0x7a,
      0xa5,
      0x55,
      0x5a,
    ]);
    expect(release, [
      0xfe,
      0x5a,
      0xaa,
      0xa5,
      0x10,
      0,
      3,
      1,
      1,
      0,
      8,
      0,
      0x67,
      0,
      0,
      0,
      3,
      0,
      0,
      0,
      0x78,
      0xa5,
      0x55,
      0x5a,
    ]);
  });

  // 真机抓包恢复出来的 MCU→SoC 属性帧，逐字节回归。见 cfcpPropFrame 注释。
  test('property frame reproduces the captured handshake frame byte-for-byte', () {
    final f = cfcpPropFrame(0x21417310, 0, intValue: 1);
    expect(f, _hex('fe5aaaa51102750101000e000c0010734121000000000100000075a5555a'));
  });

  test('property frame reproduces the captured MCU-version string frame', () {
    final f = cfcpPropFrame(
      0x21701002,
      0,
      strValue: 'SW.1.00.56 AE5I',
      strLen: 24,
    );
    expect(
      f,
      _hex(
        'fe5aaaa511027501010022002000021070210000000053572e312e30302e35'
        '3620414535490000000000000000003ca5555a',
      ),
    );
  });

  test('property frame length fields are consistent', () {
    final f = cfcpPropFrame(0x21709702, 0, intValue: 9);
    final v = ByteData.sublistView(f);
    final outer = v.getUint16(10, Endian.little);
    final inner = v.getUint16(12, Endian.little);
    expect(f.length, 26 + 4); // 固定头 26 + int 负载 4
    expect(outer, inner + 2);
    expect(inner, 12);
    expect(f.sublist(f.length - 3), [0xa5, 0x55, 0x5a]);
  });

  // guest 真机广播的 ACK 帧（原样锁死，2026-11-02 抓包）：
  //   fe 5a aa a5 | 90 08 55 | 01 01 00 | 00 00 | 10 | a5 55 5a
  test('ack frame reproduces the captured guest ack byte-for-byte', () {
    expect(cfcpAckFrame(), [
      0xfe, 0x5a, 0xaa, 0xa5, // magic
      0x90, 0x08, 0x55, // ACK 帧头
      0x01, 0x01, 0x00, // 版本/方向常量
      0x00, 0x00, // len = 0
      0x10, // ~sum(bytes[4..11]) = ~0xef
      0xa5, 0x55, 0x5a, // 帧尾
    ]);
    expect(cfcpAckFrame().length, 16);
  });

  // guest 真机广播的档位帧（2 字节负载 ⇒ 28 B）：
  //   fe 5a aa a5 | 11 02 75 | 01 01 00 | 0c 00 | 0a 00 | 02 97 70 21 |
  //   00 00 00 00 | 08 00 | 2d | a5 55 5a
  // 之前 describeFrame 把 28 B 判成「过短」，阈值已从 30 改成 26。
  test('property frame reproduces the captured 2-byte gear frame', () {
    final f = cfcpPropFrame(0x21709702, 0, rawValue: [8, 0]);
    expect(f.length, 28);
    expect(f, [
      0xfe, 0x5a, 0xaa, 0xa5, // magic
      0x11, 0x02, 0x75, // 属性帧头
      0x01, 0x01, 0x00, // 版本/方向常量
      0x0c, 0x00, // len = inner + 2 = 12
      0x0a, 0x00, // inner = 4 + 4 + 2 = 10
      0x02, 0x97, 0x70, 0x21, // prop = 0x21709702
      0x00, 0x00, 0x00, 0x00, // sub = 0
      0x08, 0x00, // 值（2 字节小端）= 8
      0x2d, // ~sum(bytes[4..23])
      0xa5, 0x55, 0x5a, // 帧尾
    ]);
  });

  test('cfcpParseProp round-trips int32, uint16 and string payloads', () {
    final i = cfcpParseProp(cfcpPropFrame(0x21407072, 0, intValue: 0xffffff1d));
    expect(i, isNotNull);
    expect(i!.prop, 0x21407072);
    expect(i.sub, 0);
    expect(i.value.length, 4);
    expect(i.asInt, -227); // getInt32 是有符号的

    final u = cfcpParseProp(cfcpPropFrame(0x21709702, 0, rawValue: [10, 0]));
    expect(u, isNotNull);
    expect(u!.value.length, 2);
    expect(u.asU16, 10);
    expect(u.asInt, isNull); // 2 字节负载不是 int32

    final s = cfcpParseProp(
      cfcpPropFrame(0x21701002, 0, strValue: 'SW.1.00.56 AE5I', strLen: 24),
    );
    expect(s, isNotNull);
    expect(s!.asText, 'SW.1.00.56 AE5I');

    // 非属性帧（键帧）不应被误解析
    expect(cfcpParseProp(cfcpKeyFrame(0xd2, true)), isNull);
  });
}

List<int> _hex(String s) {
  final out = <int>[];
  for (var i = 0; i + 1 < s.length; i += 2) {
    out.add(int.parse(s.substring(i, i + 2), radix: 16));
  }
  return out;
}
