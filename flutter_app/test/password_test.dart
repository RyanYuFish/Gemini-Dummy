// 固件原生密码界面的 MCU 侧协议回归（docs/EMULATION.md §49）。
//
// 界面由 guest 里的 Qt 类 PasswordUL / PasswordULFB70 绘制；本文件验证的是
// **MCU 侧**的 4 位密码会话、6 B `Power_On_Passwd` 属性帧，以及客户端
// 状态机不再保存任何可用于绘制密码界面的数据。
import 'dart:typed_data';

import 'package:ae5i_emu/emu/cfcp.dart';
import 'package:ae5i_emu/emu/dash_up.dart';
import 'package:ae5i_emu/emu/password.dart';
import 'package:ae5i_emu/emu/vehicle.dart';
import 'package:flutter_test/flutter_test.dart';

String _hex(List<int> b) =>
    b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();

/// tools/dash_up.py `power_passwd_frame()` 的输出（逐字节 diff 用）。
const _reference = <String, String>{
  'clear': 'fe5aaaa511027501010010000e0001977021000000003030303000006ea5555a',
  'goIntoUi':
      'fe5aaaa511027501010010000e0001977021000000003030303040002ea5555a',
  'checkSuccess':
      'fe5aaaa511027501010010000e0001977021000000003030303010005ea5555a',
  'tryError':
      'fe5aaaa511027501010010000e00019770210000000030303030080066a5555a',
  'verify':
      'fe5aaaa511027501010010000e000197702100000000313233348000e4a5555a',
};

/// 把 "1234" 变成固件提交帧的 6 B 结构（bit7 = verify_status）。
List<int> _submit(String digits, {int bits = PowerOnPasswdBit.verifyStatus}) =>
    <int>[
      ...digits.codeUnits,
      bits,
      0,
    ];

void main() {
  group('Power_On_Passwd 6 B 属性帧', () {
    test('与 tools/dash_up.py 逐字节一致', () {
      expect(_hex(dashPowerPasswdFrame()), _reference['clear']);
      expect(
        _hex(dashPowerPasswdFrame(bits: PowerOnPasswdBit.goIntoUi)),
        _reference['goIntoUi'],
      );
      expect(
        _hex(dashPowerPasswdFrame(bits: PowerOnPasswdBit.checkSuccess)),
        _reference['checkSuccess'],
      );
      expect(
        _hex(dashPowerPasswdFrame(bits: PowerOnPasswdBit.tryNumberError)),
        _reference['tryError'],
      );
      expect(
        _hex(dashPowerPasswdFrame(
            bits: PowerOnPasswdBit.verifyStatus, digits: '1234'.codeUnits)),
        _reference['verify'],
      );
    });

    test('帧可被 CFCP 解析器还原成 prop=0x21709701 / 6 B 负载', () {
      final parsed =
          cfcpParseProp(dashPowerPasswdFrame(bits: PowerOnPasswdBit.goIntoUi));
      expect(parsed, isNotNull);
      expect(parsed!.prop, DashProp.powerOnPasswd);
      expect(parsed.sub, 0);
      expect(parsed.value, [0x30, 0x30, 0x30, 0x30, 0x40, 0]);
    });
  });

  group('MCU 侧密码会话（4 位，客户端无界面）', () {
    test('未激活时按键一律 pending', () {
      final pw = McuPassword();
      expect(pw.key(PasswordKey.set), PasswordResult.pending);
      expect(pw.active, isFalse);
    });

    test('上/下循环选数字，BACK 删上一位，SET 满 4 位才校验', () {
      final pw = McuPassword()..begin();
      expect(pw.key(PasswordKey.up), PasswordResult.pending);
      expect(pw.cursor, 1);
      expect(pw.key(PasswordKey.down), PasswordResult.pending);
      expect(pw.cursor, 0);
      for (var i = 0; i < 3; i++) {
        expect(pw.key(PasswordKey.set), PasswordResult.pending);
      }
      expect(pw.digits.length, 3);
      expect(pw.key(PasswordKey.back), PasswordResult.pending);
      expect(pw.digits.length, 2);
      // 默认密码 0000：再补两位 0 即通过
      expect(pw.key(PasswordKey.set), PasswordResult.pending);
      expect(pw.key(PasswordKey.set), PasswordResult.accepted);
      expect(pw.active, isFalse);
    });

    test('密码错误 → rejected + 错误次数累加，会话保持可重试', () {
      final pw = McuPassword(pin: '2468')..begin();
      PasswordResult last = PasswordResult.pending;
      for (var i = 0; i < 4; i++) {
        last = pw.key(PasswordKey.set);
      }
      expect(last, PasswordResult.rejected);
      expect(pw.failures, 1);
      expect(pw.active, isTrue);
      expect(pw.digits, isEmpty);
    });

    test('固件提交帧（ASCII 4 位 + bit7）由 MCU 校验', () {
      final pw = McuPassword(pin: '1234')..begin();
      expect(pw.verifyFrame(_submit('1234')), PasswordResult.accepted);
      expect(pw.active, isFalse);
    });

    test('固件提交帧错误 → rejected', () {
      final pw = McuPassword(pin: '1234')..begin();
      expect(pw.verifyFrame(_submit('9999')), PasswordResult.rejected);
      expect(pw.failures, 1);
      expect(pw.active, isTrue);
    });

    test('MCU→仪表的 GO_INTO_UI 回显不会被误判成提交', () {
      final pw = McuPassword()..begin();
      expect(
        pw.verifyFrame([0x30, 0x30, 0x30, 0x30,
          PowerOnPasswdBit.goIntoUi, 0]),
        PasswordResult.pending,
      );
    });

    test('shutdown_notify（长按 BACK / 倒计时归零）→ 关机，不再比对密码', () {
      final pw = McuPassword(pin: '1234')..begin();
      // 固件 PasswordUL::shutDown() 发的帧：4 位数字无意义，关键是 bit5。
      expect(
        pw.verifyFrame([
          0x30, 0x30, 0x30, 0x30,
          PowerOnPasswdBit.shutdownNotify, 0,
        ]),
        PasswordResult.shutdown,
      );
      expect(pw.active, isFalse, reason: '关机后必须结束密码会话');
      expect(pw.failures, 0, reason: '关机不是密码错误');
    });

    test('非 ASCII 数字或长度不对的帧被忽略', () {
      final pw = McuPassword()..begin();
      expect(pw.verifyFrame([0, 0, 0, 0, 0x80, 0]),
          PasswordResult.pending);
      expect(pw.verifyFrame([0x31, 0x32, 0x33, 0x80]),
          PasswordResult.pending);
    });
  });

  test('AE5I 原生 Qt 校验结果：零载荷 bit4 只在活动会话中有效', () {
    final pw = McuPassword();
    expect(pw.verifyFrame([0,0,0,0,0x10,0]), PasswordResult.pending);
    pw.begin();
    expect(pw.verifyFrame([0,0,0,0,0,0]), PasswordResult.pending);
    expect(pw.verifyFrame([0,0,0,0,0x40,0]), PasswordResult.pending);
    expect(pw.verifyFrame([0,0,0,0,0x10,0]), PasswordResult.accepted);
    expect(pw.active, false);
  });
  group('客户端状态机不保存密码界面数据', () {
    test('只有 MCU 的 passwordVerified 事件能解锁', () {
      final m = VehicleMachine();
      m.dispatch(VehicleEvent.powerOn);
      m.dispatch(VehicleEvent.longPressReady);
      m.passwordRequiredThisBoot = true; // 手把键唤醒 + 手机未连接
      m.dispatch(VehicleEvent.bootReady);
      expect(m.dispatch(VehicleEvent.longPressReady).effect,
          VehicleEffect.promptPassword);
      for (var i = 0; i < 8; i++) {
        m.dispatch(VehicleEvent.pwSet);
      }
      expect(m.state, VehicleState.locked,
          reason: '客户端按键只能透传，不能自己判密码');
      expect(m.dispatch(VehicleEvent.passwordVerified).accepted, isTrue);
      expect(m.state, VehicleState.unlocked);
    });
  });

  group('MCU 自动关机信号帧 (MCU_SIGNAL_AUTOMATIC_SHUTDOWN)', () {
    test('dashAutoShutdownFrame 只置 payload[0]=0x01，不置解锁 bit', () {
      final parsed = cfcpParseProp(dashAutoShutdownFrame());
      expect(parsed, isNotNull);
      expect(parsed!.prop, DashProp.sync);
      expect(parsed.sub, 0);
      expect(parsed.value, [0x01, 0, 0, 0, 0, 0, 0, 0]);
    });

    test('与解锁帧互斥：dashSyncFrame(true) 只置 byte[1] bit2', () {
      final unlock = cfcpParseProp(dashSyncFrame(true))!;
      final auto = cfcpParseProp(dashAutoShutdownFrame())!;
      expect(unlock.value[1] & 0x04, 0x04); // 解锁通知
      expect(auto.value[1] & 0x04, 0); // 自动关机帧不带解锁
      expect(auto.value[0], 0x01); // 自动关机位
    });
  });

  group('密码页空闲自动关机（固件不响应 AUTOMATIC_SHUTDOWN，MCU 自己计时）', () {
    DashUpFeeder _feeder(List<Uint8List> sent,
        {Duration delay = const Duration(milliseconds: 30),
        void Function()? onShutdown}) {
      return DashUpFeeder(
        send: (f) async => sent.add(f),
        paintedPct: () => 0.0,
        animating: () => false,
        onLog: (_) {},
        onPhase: (_, __) {},
        onPasswordShutdown: onShutdown,
        requirePassword: true,
        passwordAutoShutdownDelay: delay,
        passwordTimeout: const Duration(seconds: 5),
        preArmTimeout: const Duration(seconds: 5),
      );
    }

    test('宽限期满仍未解锁 → 触发 onPasswordShutdown（自动关机）', () async {
      var shutdown = false;
      final sent = <Uint8List>[];
      final f = _feeder(sent, onShutdown: () => shutdown = true);
      await f.passwordBegin();
      await Future.delayed(const Duration(milliseconds: 150));
      expect(shutdown, isTrue, reason: '宽限期满应自动关机');
    });

    test('宽限期内解锁 → 不触发自动关机', () async {
      var shutdown = false;
      final sent = <Uint8List>[];
      // 宽限期必须大于 passwordBegin 自身的 120ms 睡眠，否则定时器会在解锁前
      // 于 passwordBegin 内部就触发（那是测试时序假象，不是逻辑缺陷）。
      final f = _feeder(sent,
          delay: const Duration(milliseconds: 300),
          onShutdown: () => shutdown = true);
      await f.passwordBegin();
      // 模拟固件提交正确密码（默认 0000）→ 客户端校验通过 → 取消定时器
      await f.passwordFromFirmware(_submit('0000'));
      await Future.delayed(const Duration(milliseconds: 250));
      expect(shutdown, isFalse, reason: '已解锁不应再触发自动关机');
    });

    test('用户持续按键 → 每次活动重置宽限期，不误关机', () async {
      var shutdown = false;
      final sent = <Uint8List>[];
      // 宽限期必须大于 passwordBegin 自身的 120ms 睡眠，否则定时器会在 begin
      // 内部睡眠期间就触发（测试时序假象，不是逻辑缺陷）。
      final f = _feeder(sent,
          delay: const Duration(milliseconds: 300),
          onShutdown: () => shutdown = true);
      await f.passwordBegin();
      // 反复按 上（模拟用户正在选数字）：每次都应重置空闲倒计时
      for (var i = 0; i < 5; i++) {
        await f.passwordKey(PasswordKey.up);
        await Future.delayed(const Duration(milliseconds: 60));
      }
      expect(shutdown, isFalse, reason: '持续输入不应触发自动关机');
    });
  });
}
