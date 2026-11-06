// 纯 Dart 自检：固件原生密码界面的 MCU 侧协议 + 客户端状态机。
//
// 与 test/password_test.dart / vehicle_test.dart 覆盖同一批断言，但不 import
// flutter_test，因此不需要 flutter 工具链（不会触碰 engine.stamp），可在
// CI / 受限沙箱里直接跑：
//
//   dart run tool/password_check.dart
//
// 帧字节同时可与 tools/dash_up.py 的 power_passwd_frame() 做 diff。
// ignore_for_file: avoid_print
import 'package:ae5i_emu/emu/cfcp.dart';
import 'package:ae5i_emu/emu/dash_up.dart';
import 'package:ae5i_emu/emu/password.dart';
import 'package:ae5i_emu/emu/vehicle.dart';

int _checks = 0;

void _expect(Object? actual, Object? expected, String what) {
  _checks++;
  if (actual != expected) {
    throw StateError('$what: 期望 $expected，实际 $actual');
  }
}

String _hex(List<int> b) =>
    b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();

void main() {
  // 1. 6 B Power_On_Passwd 帧字节（与 tools/dash_up.py 逐字节一致）。
  const reference = <String, String>{
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
  _expect(_hex(dashPowerPasswdFrame()), reference['clear'], '清位帧');
  _expect(
    _hex(dashPowerPasswdFrame(bits: PowerOnPasswdBit.goIntoUi)),
    reference['goIntoUi'],
    'GO_INTO_UI 帧',
  );
  _expect(
    _hex(dashPowerPasswdFrame(bits: PowerOnPasswdBit.checkSuccess)),
    reference['checkSuccess'],
    '校验成功帧',
  );
  _expect(
    _hex(dashPowerPasswdFrame(bits: PowerOnPasswdBit.tryNumberError)),
    reference['tryError'],
    '错误锁定帧',
  );
  _expect(
    _hex(dashPowerPasswdFrame(
        bits: PowerOnPasswdBit.verifyStatus, digits: '1234'.codeUnits)),
    reference['verify'],
    '仪表提交校验帧',
  );

  final parsed =
      cfcpParseProp(dashPowerPasswdFrame(bits: PowerOnPasswdBit.goIntoUi));
  _expect(parsed?.prop, DashProp.powerOnPasswd, '解析出的属性 id');
  _expect(parsed?.sub, 0, '解析出的子索引');
  _expect(parsed?.value.join(','), '48,48,48,48,64,0', '解析出的 6 B 负载');

  // 2. MCU 侧密码会话（4 位，客户端没有界面状态）。
  final pw = McuPassword()..begin();
  _expect(pw.key(PasswordKey.up), PasswordResult.pending, '上键');
  _expect(pw.cursor, 1, '上键后的数字');
  _expect(pw.key(PasswordKey.down), PasswordResult.pending, '下键');
  _expect(pw.cursor, 0, '下键后的数字');
  _expect(pw.key(PasswordKey.set), PasswordResult.pending, '第 1 位');
  _expect(pw.key(PasswordKey.set), PasswordResult.pending, '第 2 位');
  _expect(pw.key(PasswordKey.back), PasswordResult.pending, 'BACK');
  _expect(pw.digits.length, 1, 'BACK 后已确认位数');
  _expect(pw.key(PasswordKey.set), PasswordResult.pending, '第 2 位（重输）');
  _expect(pw.key(PasswordKey.set), PasswordResult.pending, '第 3 位');
  _expect(pw.key(PasswordKey.set), PasswordResult.accepted, '第 4 位 → 通过');
  _expect(pw.active, false, '通过后会话关闭');

  final bad = McuPassword(pin: '2468')..begin();
  PasswordResult last = PasswordResult.pending;
  for (var i = 0; i < 4; i++) {
    last = bad.key(PasswordKey.set);
  }
  _expect(last, PasswordResult.rejected, '错误密码');
  _expect(bad.failures, 1, '错误次数');
  _expect(bad.active, true, '失败后会话仍可重试');

  final submitted = McuPassword(pin: '1234')..begin();
  _expect(
    submitted.verifyFrame([0x31, 0x32, 0x33, 0x34, 0x80, 0]),
    PasswordResult.accepted,
    '固件 PasswordUL 提交正确密码',
  );
  final echo = McuPassword()..begin();
  _expect(
    echo.verifyFrame([0x30, 0x30, 0x30, 0x30, 0x40, 0]),
    PasswordResult.pending,
    'GO_INTO_UI 回显不算提交',
  );
  final stop = McuPassword()..begin();
  _expect(
    stop.verifyFrame([0x30, 0x30, 0x30, 0x30, 0x20, 0]),
    PasswordResult.shutdown,
    'shutdown_notify（长按 BACK / 倒计时归零）→ 关机',
  );
  _expect(stop.active, false, '关机后结束密码会话');

  // 3. 客户端状态机：按键不能解锁，只有 MCU 回报可以。
  final m = VehicleMachine();
  m.dispatch(VehicleEvent.powerOn);
      m.dispatch(VehicleEvent.longPressReady);
  m.passwordRequiredThisBoot = true; // 手把键唤醒 + 手机未连接
  m.dispatch(VehicleEvent.bootReady);
  _expect(
    m.dispatch(VehicleEvent.longPressReady).effect,
    VehicleEffect.promptPassword,
    '无连接长按 Ready 请求原生界面',
  );
  _expect(m.passwordMode, true, '进入密码会话');
  for (var i = 0; i < 8; i++) {
    m.dispatch(VehicleEvent.pwSet);
  }
  _expect(m.state, VehicleState.locked, '客户端按键不能自己解锁');
  _expect(m.dispatch(VehicleEvent.passwordVerified).accepted, true,
      'MCU 校验通过事件被接受');
  _expect(m.state, VehicleState.unlocked, '整车已解锁');
  _expect(m.passwordMode, false, '密码会话结束');

  print('RESULT PASS · $_checks 项断言（帧字节 / MCU 校验 / 状态机）');
}
