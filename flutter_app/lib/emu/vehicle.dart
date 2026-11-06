// 整车状态机：把真实 AE5i 的「上电 → 解锁 → Ready → 关机 → 拔电」流程
// 建模成客户端可控的状态机，用来驱动 QEMU 仪表的上/下电。
//
// 真车事实（车主确认，2026-11-01）：
//   1. 上电后刷卡 = 直接解锁；
//   2. 蓝牙连上 TBOX 后长按 Ready = 解锁；
//   3. App 点解锁（TBOX 信号）= 解锁；
//   4. 以上都没有 → 长按 Ready，仪表进入**固件原生**密码界面（PasswordUL /
//      PasswordULFB70），上/下/SET/BACK 由固件自己渲染输入，MCU 侧校验；
//   5. 停车先刷卡关机 / 长按 Ready 关机，再拔电源；直接拔电源属异常下电，
//      可能损伤车辆电力系统。
//
// 边界（与 EMULATION.md §18、§49 一致）：
//   本状态机只驱动客户端与 QEMU 生命周期。**密码的数字、校验、以及界面
//   全部不在客户端**：界面是固件的 Qt 类，校验在 MCU 仿真器
//   （`emu/password.dart` / `tools/dash_up.py`）。客户端只保留一个
//   `passwordMode` 标志，用来决定 framebuffer 是否直显（不遮挡固件画面）。

/// 整车状态。前 5 个是「有电」，后 3 个是「没电 / 正在没电」。
enum VehicleState {
  off, // 整车断电（未上电）
  booting, // 上电中：仪表 Linux/Qt 启动
  locked, // 已上电：仪表亮，未解锁
  unlocked, // 已解锁（可骑行，但未 Ready）
  ready, // Ready：动力就绪
  poweringOff, // 正常关机中：等 guest 报 Power down
  poweredOff, // 已关机：等待拔电
  unsafeCut, // 异常下电：未关机直接拔电
}

extension VehicleStateX on VehicleState {
  String get label => switch (this) {
    VehicleState.off => '断电',
    VehicleState.booting => '上电中',
    VehicleState.locked => '未解锁',
    VehicleState.unlocked => '已解锁',
    VehicleState.ready => 'READY',
    VehicleState.poweringOff => '关机中',
    VehicleState.poweredOff => '12V 通电 · 已锁定',
    VehicleState.unsafeCut => '异常下电',
  };

  /// 整车有电（含关机过程中）。
  bool get isPowered => switch (this) {
    VehicleState.booting ||
    VehicleState.locked ||
    VehicleState.unlocked ||
    VehicleState.ready ||
    VehicleState.poweringOff ||
    VehicleState.poweredOff => true,
    _ => false,
  };

  /// 仪表已在跑（可以注入按键）。
  bool get isLive => switch (this) {
    VehicleState.locked ||
    VehicleState.unlocked ||
    VehicleState.ready => true,
    _ => false,
  };

  /// 面板正在显示内容：对应真车「解锁后仪表才点亮」，且**下电过程中面板
  /// 仍在亮着**（原厂会先播 logo-out 关机动画，再由 poweroff 把屏变黑）。
  ///
  /// 2026-11-05 修复：旧实现漏了 `poweringOff`，一点「停止 / 下电」UI 就
  /// 立刻切到待机占位，把模型正在倒放的 112 帧 logo 完全盖住 ⇒ 用户看到
  /// 的「关机动画缺失」其实是客户端遮挡，不是模型没播。
  bool get isAwake => switch (this) {
    VehicleState.unlocked ||
    VehicleState.ready ||
    VehicleState.poweringOff => true,
    _ => false,
  };

  /// 主流程条上的位置：断电 › 上电 › 未解锁 › 已解锁 › READY › 关机 › 拔电。
  int get flowIndex => switch (this) {
    VehicleState.off => 0,
    VehicleState.booting => 2,
    VehicleState.locked => 2,
    VehicleState.unlocked => 3,
    VehicleState.ready => 4,
    VehicleState.poweringOff => 5,
    VehicleState.poweredOff => 1,
    VehicleState.unsafeCut => 6,
  };

  /// 下一步该做什么（UI 提示 + 日志）。
  String get nextStep => switch (this) {
    VehicleState.off => '先接通实车 12V 电源；断电时刷卡与 Ready 均无效',
    VehicleState.booting => 'MCU 启动 + 仪表就绪中（此阶段仪表黑屏待机属正常，点亮发生在解锁后）',
    VehicleState.locked => '仪表待机：刷卡 / 蓝牙连 TBOX 后长按 Ready / App 解锁；手把键唤醒且手机未连时才进固件原生密码界面（4 位，MCU 校验）',
    VehicleState.unlocked => '短按 Ready 进入前进 READY；长按 Ready 或刷卡关机',
    VehicleState.ready => '停车：刷卡关机或长按 Ready 关机，等仪表断电后再拔电',
    VehicleState.poweringOff => '等 guest 报 Power down；超时可强制拔电',
    VehicleState.poweredOff => '12V 已通电、仪表已锁定：刷卡直接开机；长按 Ready 按 TBOX 蓝牙钥匙连接情况进入密码页或直接开机',
    VehicleState.unsafeCut => '异常下电已记录；重新上电前建议确认车辆电力系统',
  };
}

/// 本次上电的唤醒来源。
///
/// 真车（用户 2026-11-06 确认）：只有「手把键唤醒（MCU 唤醒）且手机未连接」
/// 才要求开机密码；刷卡、App/TBOX 解锁、蓝牙已连手机都不弹密码页。
/// 这个来源决定了 pre-arm 阶段要不要给固件上报 `Power_On_Passwd` 的
/// go-into-UI 位，所以必须在启动仪表之前就确定。
enum VehicleWakeSource {
  none,
  mcu, // 手把键 / 整车钥匙唤醒（需要判断手机是否连接）
  nfc, // 刷 NFC 卡
  app, // App / TBOX 远程解锁
}

/// 触发状态机的事件。
enum VehicleEvent {
  powerOn, // 上电
  bootReady, // 仪表首帧到达（启动完成）
  swipeCard, // 刷 NFC 卡
  appUnlock, // App 点解锁（TBOX 信号）
  pressReady, // 短按 Ready：已解锁后进入前进 READY
  longPressReady, // 长按 Ready
  pwUp, // 密码输入：上键（原样透传给仪表 + MCU 会话）
  pwDown, // 密码输入：下键（原样透传给仪表 + MCU 会话）
  pwSet, // 密码输入：SET（原样透传给仪表 + MCU 会话）
  pwBack, // 密码输入：BACK（原样透传给仪表 + MCU 会话）
  passwordVerified, // MCU 校验通过：原生密码流程完成，整车解锁
  shutdownRequest, // 客户端「停止 / 下电」
  guestPowerDown, // guest 报 Power down
  unplug, // 拔电
  forceCut, // 确认异常下电
  fault, // 仪表进程异常退出 / 上电失败
}

/// 状态机要求宿主执行的动作。
enum VehicleEffect {
  none,
  startGuest, // 启动 QEMU 仪表
  stopGuest, // 请求 guest 正常关机
  promptPassword, // 弹密码输入
  confirmUnsafeCut, // 弹「未关机拔电」风险确认
}

class VehicleDecision {
  final VehicleEvent event;
  final bool accepted;
  final VehicleState state;

  /// 状态迁移后的日志行；空串表示不写日志。
  final String message;
  final VehicleEffect effect;

  /// 给用户看的一句话（SnackBar / 面板提示）。
  final String hint;

  const VehicleDecision({
    required this.event,
    required this.accepted,
    required this.state,
    required this.message,
    required this.effect,
    required this.hint,
  });

  @override
  String toString() =>
      'VehicleDecision(${event.name} → ${state.name}, '
      'accepted=$accepted, effect=${effect.name})';
}

/// 纯逻辑状态机：不碰进程、不碰 UI，便于单测。
class VehicleMachine {
  VehicleMachine();

  VehicleState state = VehicleState.off;

  /// 蓝牙是否已连上 TBOX（长按 Ready 解锁的前置条件）。
  bool bleConnected = false;

  bool passwordConfigured = true;

  /// TBOX 是否在线（App 解锁走 TBOX 信号，不要求蓝牙）。
  bool tboxOnline = false;

  /// 手机是否已连接 = 蓝牙是否连着 TBOX（真车「仪表蓝牙灯」）。
  ///
  /// ★ 不能用 `tboxOnline` 代替：TBOX 云端在线只代表 App 通道可用，
  /// 手机并不一定在附近；手把键唤醒时手机没连 BLE 仍必须要求密码。
  /// App 远程解锁走独立的 `appUnlock` 事件（要求 `tboxOnline`）。
  bool get phoneConnected => bleConnected;

  /// 本次上电的唤醒来源（决定是否要求开机密码）。
  VehicleWakeSource wakeSource = VehicleWakeSource.none;

  /// 本次上电是否要求开机密码（由控制器在启动仪表前按
  /// `车已设密码 && 唤醒来源 == mcu && 手机未连接` 计算并写入）。
  ///
  /// 固件只在 `initWidget()` 读一次 go-into-UI 位，所以这个值一旦启动
  /// 就不能再改；`passwordMode` 是它在 UI 侧的表现。
  bool passwordRequiredThisBoot = false;

  /// 是否正在「等待固件原生密码界面」阶段（仅 locked 状态下有意义）。
  /// 真车：手把键唤醒且手机未连接时，MCU 请求仪表 `PasswordUL` 显示。
  /// 客户端靠它决定不遮挡 framebuffer；**不保存任何数字/光标/错误次数**。
  bool passwordMode = false;

  /// 刷卡/App 唤醒时置位：上电完成后直接进「已解锁」，对应真车刷卡即解锁。
  bool _pendingUnlock = false;

  bool get pendingUnlock => _pendingUnlock;

  VehicleDecision dispatch(VehicleEvent event, {String? pinInput}) {
    switch (event) {
      case VehicleEvent.powerOn:
        return _powerOn();
      case VehicleEvent.bootReady:
        return _bootReady();
      case VehicleEvent.swipeCard:
        return _swipeCard();
      case VehicleEvent.appUnlock:
        return _appUnlock();
      case VehicleEvent.pressReady:
        if (state != VehicleState.unlocked) {
          return _ignore(event, '车辆解锁后才可进入前进 READY');
        }
        return _accept(event, VehicleState.ready, VehicleEffect.none, 'Ready 短按 → 前进 READY');
      case VehicleEvent.longPressReady:
        return _ready();
      case VehicleEvent.pwUp:
        return _pwUp();
      case VehicleEvent.pwDown:
        return _pwDown();
      case VehicleEvent.pwSet:
        return _pwSet();
      case VehicleEvent.pwBack:
        return _pwBack();
      case VehicleEvent.passwordVerified:
        return _passwordVerified();
      case VehicleEvent.shutdownRequest:
        return _shutdown('客户端下电');
      case VehicleEvent.guestPowerDown:
        return _guestPowerDown();
      case VehicleEvent.unplug:
        return _unplug();
      case VehicleEvent.forceCut:
        return _forceCut();
      case VehicleEvent.fault:
        return _fault();
    }
  }

  // ---------------------------------------------------------------- 迁移

  VehicleDecision _powerOn() {
    if (state.isPowered) {
      return _ignore(VehicleEvent.powerOn, '整车已上电（${state.label}）');
    }
    _pendingUnlock = false;
    passwordMode = false;
    passwordRequiredThisBoot = false;
    // 手把键 / 整车钥匙唤醒：是否弹密码页要等控制器结合
    // 「已设密码 + 手机是否连接」再算（passwordRequiredThisBoot）。
    wakeSource = VehicleWakeSource.none;
    return _accept(
      VehicleEvent.powerOn,
      VehicleState.poweredOff,
      VehicleEffect.none,
      '12V 系统已通电：MCU 待机，仪表保持锁定；等待刷卡或长按 Ready',
    );
  }

  VehicleDecision _bootReady() {
    if (state != VehicleState.booting) {
      return _ignore(VehicleEvent.bootReady, '仪表启动完成事件被忽略（当前 ${state.label}）');
    }
    final unlock = _pendingUnlock;
    _pendingUnlock = false;
    // ★ 不能在这里无条件清 passwordMode：需要密码的本次上电，固件在
    //   initWidget 阶段就已经把原生 PasswordUL 建出来并画在 framebuffer 上，
    //   清掉会让客户端用待机占位把密码页盖住。
    if (unlock) passwordMode = false;
    return unlock
        ? _accept(
            VehicleEvent.bootReady,
            VehicleState.unlocked,
            VehicleEffect.none,
            '仪表启动完成 → 已解锁（刷卡/App 唤醒）',
          )
        : _accept(
            VehicleEvent.bootReady,
            VehicleState.locked,
            VehicleEffect.none,
            passwordMode
                ? '仪表启动完成 → 固件显示原生密码解锁页，等待输入'
                : '仪表启动完成 → 未解锁，等待刷卡 / Ready / App',
          );
  }

  VehicleDecision _swipeCard() {
    switch (state) {
      case VehicleState.poweredOff:
        // 12V 已通电，刷卡从锁定待机唤醒。
        // NFC 唤醒不走开机密码，pre-arm 不能上报 go-into-UI。
        wakeSource = VehicleWakeSource.nfc;
        _pendingUnlock = true;
        return _accept(
          VehicleEvent.swipeCard,
          VehicleState.booting,
          VehicleEffect.startGuest,
          '刷卡解锁：启动仪表与车辆电源，不需要开机密码',
        );
      case VehicleState.booting:
        // 启动途中刷卡：撤销本次密码要求（固件若已建页，控制器会发
        // check_passwd_success 让它收掉），启动完成后直接解锁。
        _pendingUnlock = true;
        passwordRequiredThisBoot = false;
        passwordMode = false;
        return _ignore(VehicleEvent.swipeCard, '已记录刷卡，仪表启动后自动解锁');
      case VehicleState.locked:
        passwordMode = false;
        return _accept(
          VehicleEvent.swipeCard,
          VehicleState.unlocked,
          VehicleEffect.none,
          '刷卡解锁成功',
        );
      case VehicleState.unlocked:
      case VehicleState.ready:
        return _accept(
          VehicleEvent.swipeCard,
          VehicleState.poweringOff,
          VehicleEffect.stopGuest,
          '刷卡关机：等待仪表正常下电（下电完成后才能拔电）',
        );
      case VehicleState.poweringOff:
        return _ignore(VehicleEvent.swipeCard, '正在关机，请等待仪表断电');
      case VehicleState.off:
        return _ignore(VehicleEvent.swipeCard, '12V 系统未通电，刷卡无效');
      case VehicleState.unsafeCut:
        return _ignore(VehicleEvent.swipeCard, '整车已断电，请先上电');
    }
  }

  VehicleDecision _appUnlock() {
    if (!tboxOnline) {
      return _ignore(
        VehicleEvent.appUnlock,
        'TBOX 不在线：App 解锁需要 TBOX 联网（真车走 TBOX 信号）',
      );
    }
    switch (state) {
      case VehicleState.poweredOff:
        wakeSource = VehicleWakeSource.app;
        _pendingUnlock = true;
        return _accept(
          VehicleEvent.appUnlock,
          VehicleState.booting,
          VehicleEffect.startGuest,
          'App 解锁（TBOX 信号）：唤醒整车上电，启动后直接解锁（不需要开机密码）',
        );
      case VehicleState.booting:
        _pendingUnlock = true;
        passwordRequiredThisBoot = false;
        passwordMode = false;
        return _ignore(VehicleEvent.appUnlock, '已记录 App 解锁，仪表启动后自动解锁');
      case VehicleState.locked:
        passwordMode = false;
        return _accept(
          VehicleEvent.appUnlock,
          VehicleState.unlocked,
          VehicleEffect.none,
          'App 解锁成功（TBOX 信号）',
        );
      case VehicleState.unlocked:
      case VehicleState.ready:
        return _ignore(VehicleEvent.appUnlock, '车辆已解锁，App 解锁无副作用');
      case VehicleState.poweringOff:
      case VehicleState.off:
      case VehicleState.unsafeCut:
        return _ignore(VehicleEvent.appUnlock, '车辆正在/已经下电，App 解锁不适用');
    }
  }

  VehicleDecision _ready() {
    switch (state) {
      case VehicleState.poweredOff:
        wakeSource = VehicleWakeSource.mcu;
        _pendingUnlock = phoneConnected || !passwordConfigured;
        passwordMode = !phoneConnected && passwordConfigured;
        return _accept(
          VehicleEvent.longPressReady,
          VehicleState.booting,
          VehicleEffect.startGuest,
          phoneConnected
              ? '长按 Ready：TBOX 蓝牙钥匙已连接，仪表直接开机'
              : '长按 Ready：手把灯亮，启动仪表原生密码解锁页',
        );
      case VehicleState.locked:
        // 手机已连接（蓝牙连着 TBOX，仪表蓝牙灯亮）→ 直接解锁，不弹密码。
        if (phoneConnected) {
          return _accept(
            VehicleEvent.longPressReady,
            VehicleState.unlocked,
            VehicleEffect.none,
            '长按 Ready + 蓝牙已连手机（仪表蓝牙灯亮）→ 解锁（不需要开机密码）',
          );
        }
        // 本次上电本来就没要求密码（刷卡 / App 唤醒，或本车未设密码）：
        // 固件没有建密码页，不能在这里凭空进入密码会话。
        if (!passwordRequiredThisBoot) {
          return _accept(
            VehicleEvent.longPressReady,
            VehicleState.unlocked,
            VehicleEffect.none,
            '长按 Ready → 解锁（本次上电已在唤醒时授权，无密码页）',
          );
        }
        // 手把键唤醒 + 手机未连接：MCU 请求仪表进入原生 `PasswordUL`。
        // 上/下/SET/BACK 原样透传给固件，密码状态与校验都在 MCU 仿真器，
        // 客户端不画界面。
        passwordMode = true;
        return VehicleDecision(
          event: VehicleEvent.longPressReady,
          accepted: false,
          state: state,
          message: '长按 Ready：手机未连接，MCU 请求仪表原生密码界面（PasswordUL）',
          effect: VehicleEffect.promptPassword,
          hint: '仪表原生密码界面：上/下选数字，SET 确认，BACK 删改；'
              '长按 BACK 或等待右上角倒计时结束会关机；客户端不绘制任何密码界面',
        );
      case VehicleState.unlocked:
      case VehicleState.ready:
        return _accept(
          VehicleEvent.longPressReady,
          VehicleState.poweringOff,
          VehicleEffect.stopGuest,
          '长按 Ready 关机：等待仪表正常下电（下电完成后才能拔电）',
        );
      case VehicleState.off:
      case VehicleState.unsafeCut:
        return _ignore(VehicleEvent.longPressReady, '整车未上电，长按 Ready 无效');
      case VehicleState.booting:
        return _ignore(VehicleEvent.longPressReady, '仪表启动中，请等画面出来');
      case VehicleState.poweringOff:
        return _ignore(VehicleEvent.longPressReady, '正在关机，请等待仪表断电');
    }
  }

  // 上/下/SET/BACK 只作为「透传给仪表的原生按键」记录存在。
  // 数字、光标、错误次数、校验都在 MCU 仿真器（emu/password.dart），
  // 这里不保存任何可用于绘制界面的状态。
  VehicleDecision _pwUp() => _pwPass(VehicleEvent.pwUp, '上');
  VehicleDecision _pwDown() => _pwPass(VehicleEvent.pwDown, '下');
  VehicleDecision _pwBack() => _pwPass(VehicleEvent.pwBack, 'BACK');
  VehicleDecision _pwSet() => _pwPass(VehicleEvent.pwSet, 'SET');

  VehicleDecision _pwPass(VehicleEvent event, String label) {
    if (!passwordMode) return _ignore(event, '当前不在密码输入界面');
    return _ignore(event, '$label → 原样透传给仪表（界面由固件绘制）');
  }

  /// MCU 侧校验通过：才真正把整车推进「已解锁」。
  VehicleDecision _passwordVerified() {
    if (!passwordMode ||
        (state != VehicleState.locked && state != VehicleState.booting)) {
      return _ignore(VehicleEvent.passwordVerified, '当前不在未解锁状态');
    }
    passwordMode = false;
    return _accept(
      VehicleEvent.passwordVerified,
      VehicleState.unlocked,
      VehicleEffect.none,
      '原生密码校验通过 → 解锁',
    );
  }

  VehicleDecision _shutdown(String source) {
    switch (state) {
      case VehicleState.locked:
      case VehicleState.unlocked:
      case VehicleState.ready:
        passwordMode = false;
        return _accept(
          VehicleEvent.shutdownRequest,
          VehicleState.poweringOff,
          VehicleEffect.stopGuest,
          '$source：正常关机，等待仪表下电（下电完成后才能拔电）',
        );
      case VehicleState.booting:
        passwordMode = false;
        return _accept(
          VehicleEvent.shutdownRequest,
          VehicleState.poweringOff,
          VehicleEffect.stopGuest,
          '$source：启动中途下电，等待仪表退出',
        );
      case VehicleState.poweringOff:
        return _ignore(VehicleEvent.shutdownRequest, '正在关机，请等待');
      case VehicleState.off:
      case VehicleState.poweredOff:
      case VehicleState.unsafeCut:
        return _ignore(VehicleEvent.shutdownRequest, '整车已断电');
    }
  }

  VehicleDecision _guestPowerDown() {
    if (state == VehicleState.poweredOff) {
      return _ignore(VehicleEvent.guestPowerDown, '已记录过 guest 关机');
    }
    _pendingUnlock = false;
    return _accept(
      VehicleEvent.guestPowerDown,
      VehicleState.poweredOff,
      VehicleEffect.none,
      '仪表已锁定关机；12V 系统仍通电，可再次刷卡或长按 Ready 开机',
    );
  }

  VehicleDecision _unplug() {
    switch (state) {
      case VehicleState.off:
        return _ignore(VehicleEvent.unplug, '整车已断电，无需拔电');
      case VehicleState.poweredOff:
        return _accept(
          VehicleEvent.unplug,
          VehicleState.off,
          VehicleEffect.none,
          '拔电完成（正常下电流程已走完）',
        );
      case VehicleState.unsafeCut:
        return _accept(
          VehicleEvent.unplug,
          VehicleState.off,
          VehicleEffect.none,
          '拔电完成（本次上电曾异常下电，已记录）',
        );
      case VehicleState.booting:
      case VehicleState.locked:
      case VehicleState.unlocked:
      case VehicleState.ready:
      case VehicleState.poweringOff:
        return VehicleDecision(
          event: VehicleEvent.unplug,
          accepted: false,
          state: state,
          message: '拔电被拦截：车辆仍在 ${state.label}，未走正常关机流程',
          effect: VehicleEffect.confirmUnsafeCut,
          hint: '仪表仍通电，直接拔电属异常下电，可能损伤车辆电力系统',
        );
    }
  }

  VehicleDecision _forceCut() {
    if (!state.isPowered) {
      return _accept(
        VehicleEvent.forceCut,
        VehicleState.off,
        VehicleEffect.none,
        '已断电',
      );
    }
    final wasPoweringOff = state == VehicleState.poweringOff;
    _pendingUnlock = false;
    passwordMode = false;
    return _accept(
      VehicleEvent.forceCut,
      VehicleState.unsafeCut,
      VehicleEffect.none,
      wasPoweringOff
          ? '异常下电：仪表未确认关机即断电，可能损伤车辆电力系统'
          : '异常下电：未关机直接拔电，可能损伤车辆电力系统',
    );
  }

  VehicleDecision _fault() {
    if (state == VehicleState.booting) {
      _pendingUnlock = false;
      passwordMode = false;
      return _accept(
        VehicleEvent.fault,
        VehicleState.poweredOff,
        VehicleEffect.none,
        '仪表启动失败：12V 保持通电，可重试开机',
      );
    }
    if (state.isPowered) {
      return _accept(
        VehicleEvent.fault,
        VehicleState.unsafeCut,
        VehicleEffect.none,
        '仪表进程异常退出（等效异常断电）',
      );
    }
    return _ignore(VehicleEvent.fault, '仪表进程已结束');
  }

  // ---------------------------------------------------------------- 辅助

  VehicleDecision _accept(
    VehicleEvent event,
    VehicleState next,
    VehicleEffect effect,
    String message,
  ) {
    state = next;
    return VehicleDecision(
      event: event,
      accepted: true,
      state: next,
      message: message,
      effect: effect,
      hint: message,
    );
  }

  VehicleDecision _ignore(VehicleEvent event, String hint) => VehicleDecision(
    event: event,
    accepted: false,
    state: state,
    message: '',
    effect: VehicleEffect.none,
    hint: hint,
  );

  void reset() {
    state = VehicleState.off;
    _pendingUnlock = false;
    passwordMode = false;
    passwordRequiredThisBoot = false;
    wakeSource = VehicleWakeSource.none;
    bleConnected = false;
    tboxOnline = false;
  }
}
