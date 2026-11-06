import 'package:ae5i_emu/emu/vehicle.dart';
import 'package:flutter_test/flutter_test.dart';

VehicleMachine supplied({bool ble = false, bool tbox = false}) =>
    VehicleMachine()
      ..bleConnected = ble
      ..tboxOnline = tbox
      ..dispatch(VehicleEvent.powerOn);

VehicleMachine unlocked() => supplied()
  ..dispatch(VehicleEvent.swipeCard)
  ..dispatch(VehicleEvent.bootReady);

void main() {
  test('12V 上电仅进入 MCU 待机，不启动仪表、不要求密码', () {
    final m = VehicleMachine();
    final d = m.dispatch(VehicleEvent.powerOn);
    expect(d.effect, VehicleEffect.none);
    expect(m.state, VehicleState.poweredOff);
    expect(m.state.isPowered, true);
    expect(m.state.isAwake, false);
    expect(m.passwordMode, false);
    expect(m.wakeSource, VehicleWakeSource.none);
    expect(m.dispatch(VehicleEvent.powerOn).accepted, false);
  });

  for (final e in [VehicleEvent.swipeCard, VehicleEvent.longPressReady,
    VehicleEvent.appUnlock, VehicleEvent.pressReady]) {
    test('12V 断电时 ${e.name} 无法唤醒车辆', () {
      final m = VehicleMachine()..tboxOnline = true;
      expect(m.dispatch(e).accepted, false);
      expect(m.state, VehicleState.off);
    });
  }

  test('刷卡直接启动，无密码；再次刷卡关机，保持 12V，可反复唤醒', () {
    final m = supplied();
    for (var i = 0; i < 3; i++) {
      expect(m.dispatch(VehicleEvent.swipeCard).effect, VehicleEffect.startGuest);
      expect(m.wakeSource, VehicleWakeSource.nfc);
      expect(m.pendingUnlock, true);
      expect(m.passwordMode, false);
      m.dispatch(VehicleEvent.bootReady);
      expect(m.state, VehicleState.unlocked);
      expect(m.dispatch(VehicleEvent.swipeCard).effect, VehicleEffect.stopGuest);
      expect(m.state.isAwake, true, reason: '关机过程中继续显示 guest 画面');
      m.dispatch(VehicleEvent.guestPowerDown);
      expect(m.state, VehicleState.poweredOff);
      expect(m.state.isPowered, true);
    }
  });

  test('蓝牙钥匙连 cfmoto TBOX 时 Ready 唤醒直接解锁，不要求云端在线', () {
    final m = supplied(ble: true);
    expect(m.dispatch(VehicleEvent.longPressReady).effect, VehicleEffect.startGuest);
    expect(m.passwordMode, false);
    m.dispatch(VehicleEvent.bootReady);
    expect(m.state, VehicleState.unlocked);
  });

  test('只有 TBOX 云端在线不能跳过密码', () {
    final m = supplied(tbox: true);
    m.dispatch(VehicleEvent.longPressReady);
    m.passwordRequiredThisBoot = true;
    expect(m.pendingUnlock, false);
    expect(m.passwordMode, true);
    m.dispatch(VehicleEvent.bootReady);
    expect(m.state, VehicleState.locked);
    for (var i = 0; i < 8; i++) { m.dispatch(VehicleEvent.pwSet); }
    expect(m.state, VehicleState.locked);
    expect(m.dispatch(VehicleEvent.passwordVerified).accepted, true);
    expect(m.state, VehicleState.unlocked);
    expect(m.passwordMode, false);
  });

  test('未设置密码时 Ready 唤醒直接启动', () {
    final m = supplied()..passwordConfigured = false;
    m.dispatch(VehicleEvent.longPressReady);
    m.dispatch(VehicleEvent.bootReady);
    expect(m.state, VehicleState.unlocked);
  });

  test('App 独立授权，需要 TBOX 在线，无需蓝牙钥匙', () {
    final m = supplied();
    expect(m.dispatch(VehicleEvent.appUnlock).accepted, false);
    m.tboxOnline = true;
    expect(m.dispatch(VehicleEvent.appUnlock).effect, VehicleEffect.startGuest);
    m.dispatch(VehicleEvent.bootReady);
    expect(m.state, VehicleState.unlocked);
  });

  for (final e in [VehicleEvent.swipeCard, VehicleEvent.appUnlock]) {
    test('密码页被 ${e.name} 授权取消', () {
      final m = supplied(tbox: true)..dispatch(VehicleEvent.longPressReady);
      m.passwordRequiredThisBoot = true;
      m.dispatch(e);
      m.dispatch(VehicleEvent.bootReady);
      expect(m.state, VehicleState.unlocked);
      expect(m.passwordMode, false);
    });
  }

  test('未进入密码会话的成功通知不能解锁', () {
    final m = supplied();
    expect(m.dispatch(VehicleEvent.passwordVerified).accepted, false);
    expect(m.state, VehicleState.poweredOff);
  });

  test('解锁后短按 Ready 进入前进，长按 Ready 在 P/READY 均关机', () {
    for (final forward in [false, true]) {
      final m = unlocked();
      if (forward) {
        expect(m.dispatch(VehicleEvent.pressReady).accepted, true);
        expect(m.state, VehicleState.ready);
      }
      expect(m.dispatch(VehicleEvent.longPressReady).effect, VehicleEffect.stopGuest);
      expect(m.state, VehicleState.poweringOff);
    }
  });

  test('密码锁定期间禁止进入前进 READY', () {
    final m = supplied()..dispatch(VehicleEvent.longPressReady)
      ..dispatch(VehicleEvent.bootReady);
    expect(m.dispatch(VehicleEvent.pressReady).accepted, false);
  });

  test('12V 待机可直接断电；仪表运行时需确认异常下电', () {
    final standby = supplied();
    expect(standby.dispatch(VehicleEvent.unplug).accepted, true);
    expect(standby.state, VehicleState.off);
    final m = unlocked();
    expect(m.dispatch(VehicleEvent.unplug).effect, VehicleEffect.confirmUnsafeCut);
    m.dispatch(VehicleEvent.forceCut);
    expect(m.state, VehicleState.unsafeCut);
    m.dispatch(VehicleEvent.powerOn);
    expect(m.state, VehicleState.poweredOff);
  });

  test('仪表启动失败不虚构 12V 电源消失', () {
    final m = supplied()..dispatch(VehicleEvent.longPressReady);
    m.dispatch(VehicleEvent.fault);
    expect(m.state, VehicleState.poweredOff);
    expect(m.state.isPowered, true);
  });
}
