// 整车状态机单测：覆盖真车四条解锁路径、正常下电与异常下电。
//
// 这些用例不启动 QEMU，只验证迁移规则；进程生命周期由
// boot_integration.dart 做端到端验收。
import 'package:ae5i_emu/emu/vehicle.dart';
import 'package:flutter_test/flutter_test.dart';

/// 上电并等仪表出画面。
VehicleMachine booted({bool ble = false, bool tbox = false}) {
  final m = VehicleMachine()
    ..bleConnected = ble
    ..tboxOnline = tbox;
  m.dispatch(VehicleEvent.powerOn);
  m.dispatch(VehicleEvent.bootReady);
  return m;
}

/// 用仪表原生密码盘输完一个密码：上键选到目标数字，SET 确认下一位。
void enterPin(VehicleMachine m, String pin) {
  for (final ch in pin.split('')) {
    final d = int.parse(ch);
    while (m.pwCursor != d) {
      m.dispatch(VehicleEvent.pwUp);
    }
    m.dispatch(VehicleEvent.pwSet);
  }
}

void main() {
  group('上电', () {
    test('off + powerOn → booting 并要求启动仪表', () {
      final m = VehicleMachine();
      final d = m.dispatch(VehicleEvent.powerOn);
      expect(d.accepted, isTrue);
      expect(d.effect, VehicleEffect.startGuest);
      expect(m.state, VehicleState.booting);
    });

    test('仪表出画面后停在未解锁', () {
      final m = booted();
      expect(m.state, VehicleState.locked);
    });

    test('已上电时重复上电被拒绝', () {
      final m = booted();
      final d = m.dispatch(VehicleEvent.powerOn);
      expect(d.accepted, isFalse);
      expect(m.state, VehicleState.locked);
    });

    test('上电失败回到断电', () {
      final m = VehicleMachine()..dispatch(VehicleEvent.powerOn);
      final d = m.dispatch(VehicleEvent.fault);
      expect(d.accepted, isTrue);
      expect(m.state, VehicleState.off);
    });

    test('已关机但未拔电时拒绝重新上电，拔电后才允许', () {
      final m = booted();
      m.dispatch(VehicleEvent.swipeCard); // 未解锁 → 已解锁
      m.dispatch(VehicleEvent.swipeCard); // 已解锁 → 关机中
      m.dispatch(VehicleEvent.guestPowerDown);
      expect(m.state, VehicleState.poweredOff);
      final blocked = m.dispatch(VehicleEvent.powerOn);
      expect(blocked.accepted, isFalse, reason: '关机 ≠ 断电，必须先后拔电');
      expect(m.state, VehicleState.poweredOff);
      m.dispatch(VehicleEvent.unplug);
      final ok = m.dispatch(VehicleEvent.powerOn);
      expect(ok.accepted, isTrue);
      expect(m.state, VehicleState.booting);
    });

    test('异常下电后可直接重新上电', () {
      final m = booted();
      m.dispatch(VehicleEvent.forceCut);
      expect(m.state, VehicleState.unsafeCut);
      final d = m.dispatch(VehicleEvent.powerOn);
      expect(d.accepted, isTrue);
      expect(m.state, VehicleState.booting);
    });
  });

  group('解锁路径 1：刷卡', () {
    test('未上电刷卡 = 唤醒 + 上电 + 启动后直接解锁', () {
      final m = VehicleMachine();
      final on = m.dispatch(VehicleEvent.swipeCard);
      expect(on.effect, VehicleEffect.startGuest);
      expect(m.state, VehicleState.booting);
      expect(m.pendingUnlock, isTrue);
      m.dispatch(VehicleEvent.bootReady);
      expect(m.state, VehicleState.unlocked);
    });

    test('已上电未解锁刷卡 → 已解锁', () {
      final m = booted();
      final d = m.dispatch(VehicleEvent.swipeCard);
      expect(d.accepted, isTrue);
      expect(m.state, VehicleState.unlocked);
    });

    test('已关机未拔电时刷卡也被拦截', () {
      final m = booted();
      m.dispatch(VehicleEvent.swipeCard); // 已解锁
      m.dispatch(VehicleEvent.swipeCard); // 关机中
      m.dispatch(VehicleEvent.guestPowerDown);
      expect(m.state, VehicleState.poweredOff);
      final d = m.dispatch(VehicleEvent.swipeCard);
      expect(d.accepted, isFalse);
      expect(d.effect, VehicleEffect.none);
      expect(m.state, VehicleState.poweredOff);
    });
  });

  group('解锁路径 2：蓝牙 + 长按 Ready', () {
    test('蓝牙已连 TBOX → 直接解锁', () {
      final m = booted(ble: true);
      final d = m.dispatch(VehicleEvent.longPressReady);
      expect(d.accepted, isTrue);
      expect(m.state, VehicleState.unlocked);
    });

    test('蓝牙未连 → 转密码，状态不变', () {
      final m = booted();
      final d = m.dispatch(VehicleEvent.longPressReady);
      expect(d.accepted, isFalse);
      expect(d.effect, VehicleEffect.promptPassword);
      expect(m.state, VehicleState.locked);
    });
  });

  group('解锁路径 3：App（TBOX 信号）', () {
    test('TBOX 离线时拒绝', () {
      final m = booted();
      final d = m.dispatch(VehicleEvent.appUnlock);
      expect(d.accepted, isFalse);
      expect(m.state, VehicleState.locked);
    });

    test('TBOX 在线时解锁', () {
      final m = booted(tbox: true);
      final d = m.dispatch(VehicleEvent.appUnlock);
      expect(d.accepted, isTrue);
      expect(m.state, VehicleState.unlocked);
    });

    test('未上电 + TBOX 在线：App 唤醒上电并解锁', () {
      final m = VehicleMachine()..tboxOnline = true;
      final d = m.dispatch(VehicleEvent.appUnlock);
      expect(d.effect, VehicleEffect.startGuest);
      m.dispatch(VehicleEvent.bootReady);
      expect(m.state, VehicleState.unlocked);
    });
  });

  group('解锁路径 4：仪表原生密码盘', () {
    test('无连接长按 Ready 进入密码输入界面', () {
      final m = booted();
      final d = m.dispatch(VehicleEvent.longPressReady);
      expect(d.effect, VehicleEffect.promptPassword);
      expect(m.passwordMode, isTrue);
      expect(m.state, VehicleState.locked);
    });

    test('上/下切换当前位数字 0–9 循环', () {
      final m = booted();
      m.dispatch(VehicleEvent.longPressReady);
      m.dispatch(VehicleEvent.pwUp);
      expect(m.pwCursor, 1);
      m.dispatch(VehicleEvent.pwUp);
      expect(m.pwCursor, 2);
      m.dispatch(VehicleEvent.pwDown);
      expect(m.pwCursor, 1);
      for (var i = 0; i < 9; i++) {
        m.dispatch(VehicleEvent.pwDown);
      }
      expect(m.pwCursor, 2); // (1 - 9) mod 10 = 2
    });

    test('SET 逐位确认，输满长度才校验', () {
      final m = booted();
      m.dispatch(VehicleEvent.longPressReady);
      m.dispatch(VehicleEvent.pwSet); // 第 1 位 = 0
      expect(m.pwEntered, [0]);
      m.dispatch(VehicleEvent.pwUp);
      m.dispatch(VehicleEvent.pwSet); // 第 2 位 = 1
      expect(m.pwEntered, [0, 1]);
      expect(m.state, VehicleState.locked); // 还没输满 6 位
    });

    test('BACK 删除上一位', () {
      final m = booted();
      m.dispatch(VehicleEvent.longPressReady);
      m.dispatch(VehicleEvent.pwSet);
      m.dispatch(VehicleEvent.pwSet);
      expect(m.pwEntered, [0, 0]);
      m.dispatch(VehicleEvent.pwBack);
      expect(m.pwEntered, [0]);
    });

    test('密码错误保持未解锁并计次，可重试', () {
      final m = booted();
      m.dispatch(VehicleEvent.longPressReady);
      enterPin(m, '111111'); // 默认密码是 000000
      expect(m.state, VehicleState.locked);
      expect(m.passwordMode, isTrue);
      expect(m.failedAttempts, 1);
      expect(m.pwEntered, isEmpty); // 错后清空，等待重输
    });

    test('密码正确解锁并清零失败次数', () {
      final m = booted();
      m.dispatch(VehicleEvent.longPressReady);
      enterPin(m, '000000');
      expect(m.state, VehicleState.unlocked);
      expect(m.passwordMode, isFalse);
      expect(m.failedAttempts, 0);
    });

    test('仿真密码（手机 App 设置）可改', () {
      final m = booted()..pin = '246810';
      m.dispatch(VehicleEvent.longPressReady);
      enterPin(m, '000000');
      expect(m.state, VehicleState.locked);
      enterPin(m, '246810');
      expect(m.state, VehicleState.unlocked);
    });

    test('非密码界面时上/下/SET/BACK 无效', () {
      final m = booted();
      expect(m.dispatch(VehicleEvent.pwUp).accepted, isFalse);
      expect(m.dispatch(VehicleEvent.pwSet).accepted, isFalse);
    });
  });

  group('Ready 与正常关机', () {
    test('已解锁长按 Ready → READY', () {
      final m = booted(ble: true)..dispatch(VehicleEvent.longPressReady);
      expect(m.state, VehicleState.unlocked);
      final d = m.dispatch(VehicleEvent.longPressReady);
      expect(d.accepted, isTrue);
      expect(m.state, VehicleState.ready);
    });

    test('READY 长按 Ready → 关机并请求 guest 下电', () {
      final m = booted(ble: true);
      m.dispatch(VehicleEvent.longPressReady); // unlocked
      m.dispatch(VehicleEvent.longPressReady); // ready
      final d = m.dispatch(VehicleEvent.longPressReady);
      expect(d.effect, VehicleEffect.stopGuest);
      expect(m.state, VehicleState.poweringOff);
    });

    test('已解锁刷卡 → 关机', () {
      final m = booted()..dispatch(VehicleEvent.swipeCard);
      final d = m.dispatch(VehicleEvent.swipeCard);
      expect(d.effect, VehicleEffect.stopGuest);
      expect(m.state, VehicleState.poweringOff);
    });

    test('关机中重复刷卡不会重复下电', () {
      final m = booted()..dispatch(VehicleEvent.swipeCard);
      m.dispatch(VehicleEvent.swipeCard);
      final again = m.dispatch(VehicleEvent.swipeCard);
      expect(again.accepted, isFalse);
      expect(again.effect, VehicleEffect.none);
      expect(m.state, VehicleState.poweringOff);
    });

    test('guest 报 Power down → 已关机', () {
      final m = booted()..dispatch(VehicleEvent.swipeCard);
      final d = m.dispatch(VehicleEvent.guestPowerDown);
      expect(d.accepted, isTrue);
      expect(m.state, VehicleState.poweredOff);
    });

    test('已关机才能拔电，拔电后回到断电', () {
      final m = booted()..dispatch(VehicleEvent.swipeCard);
      m.dispatch(VehicleEvent.guestPowerDown);
      final d = m.dispatch(VehicleEvent.unplug);
      expect(d.accepted, isTrue);
      expect(m.state, VehicleState.off);
    });
  });

  group('异常下电红线', () {
    test('通电时拔电只给风险确认，不改变状态', () {
      for (final state in [
        VehicleState.locked,
        VehicleState.unlocked,
        VehicleState.ready,
      ]) {
        final m = booted(ble: true);
        if (state == VehicleState.unlocked) {
          m.dispatch(VehicleEvent.longPressReady);
        } else if (state == VehicleState.ready) {
          m.dispatch(VehicleEvent.longPressReady);
          m.dispatch(VehicleEvent.longPressReady);
        }
        expect(m.state, state, reason: '准备状态');
        final d = m.dispatch(VehicleEvent.unplug);
        expect(d.accepted, isFalse, reason: '$state 直接拔电应被拦截');
        expect(d.effect, VehicleEffect.confirmUnsafeCut);
        expect(m.state, state, reason: '拦截时状态不能变');
      }
    });

    test('确认异常下电 → unsafeCut，再拔电回到断电', () {
      final m = booted();
      final cut = m.dispatch(VehicleEvent.forceCut);
      expect(cut.accepted, isTrue);
      expect(m.state, VehicleState.unsafeCut);
      final unplug = m.dispatch(VehicleEvent.unplug);
      expect(unplug.accepted, isTrue);
      expect(m.state, VehicleState.off);
    });

    test('关机中强制拔电也记为异常下电', () {
      final m = booted();
      m.dispatch(VehicleEvent.swipeCard); // 未解锁 → 已解锁
      m.dispatch(VehicleEvent.swipeCard); // 已解锁 → 关机中
      expect(m.state, VehicleState.poweringOff);
      m.dispatch(VehicleEvent.forceCut);
      expect(m.state, VehicleState.unsafeCut);
    });

    test('运行中进程异常退出 → unsafeCut', () {
      final m = booted();
      final d = m.dispatch(VehicleEvent.fault);
      expect(d.accepted, isTrue);
      expect(m.state, VehicleState.unsafeCut);
    });
  });

  group('完整真车流程', () {
    test('上电 → 未解锁 → 刷卡 → 已解锁 → Ready → 长按关机 → 拔电', () {
      final m = VehicleMachine();
      expect(m.dispatch(VehicleEvent.powerOn).effect, VehicleEffect.startGuest);
      m.dispatch(VehicleEvent.bootReady);
      expect(m.state, VehicleState.locked);
      m.dispatch(VehicleEvent.swipeCard);
      expect(m.state, VehicleState.unlocked);
      m.dispatch(VehicleEvent.longPressReady);
      expect(m.state, VehicleState.ready);
      expect(m.dispatch(VehicleEvent.longPressReady).effect, VehicleEffect.stopGuest);
      expect(m.state, VehicleState.poweringOff);
      m.dispatch(VehicleEvent.guestPowerDown);
      expect(m.state, VehicleState.poweredOff);
      expect(m.dispatch(VehicleEvent.unplug).accepted, isTrue);
      expect(m.state, VehicleState.off);
    });

    test('无连接菜单：上电 → 长按 Ready → 密码盘 → 解锁', () {
      final m = VehicleMachine();
      m.dispatch(VehicleEvent.powerOn);
      m.dispatch(VehicleEvent.bootReady);
      final prompt = m.dispatch(VehicleEvent.longPressReady);
      expect(prompt.effect, VehicleEffect.promptPassword);
      enterPin(m, '000000');
      expect(m.state, VehicleState.unlocked);
    });
  });
}
