// 整车状态机：把真实 AE5i 的「上电 → 解锁 → Ready → 关机 → 拔电」流程
// 建模成客户端可控的状态机，用来驱动 QEMU 仪表的上/下电。
//
// 真车事实（车主确认，2026-11-01）：
//   1. 上电后刷卡 = 直接解锁；
//   2. 蓝牙连上 TBOX 后长按 Ready = 解锁；
//   3. App 点解锁（TBOX 信号）= 解锁；
//   4. 以上都没有 → 长按 Ready 提示输密码，密码正确也解锁；
//   5. 停车先刷卡关机 / 长按 Ready 关机，再拔电源；直接拔电源属异常下电，
//      可能损伤车辆电力系统。
//
// 边界（与 EMULATION.md §18 一致）：
//   仪表固件侧的 MCU/TBOX 认证帧尚未接入，本状态机只驱动客户端与 QEMU
//   生命周期，**不伪造任何未经确认的车辆总线报文**。所以「解锁」是客户端
//   仿真层状态，不是固件已认证的证据。

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
    VehicleState.poweredOff => '已关机',
    VehicleState.unsafeCut => '异常下电',
  };

  /// 整车有电（含关机过程中）。
  bool get isPowered => switch (this) {
    VehicleState.booting ||
    VehicleState.locked ||
    VehicleState.unlocked ||
    VehicleState.ready ||
    VehicleState.poweringOff => true,
    _ => false,
  };

  /// 仪表已在跑（可以注入按键）。
  bool get isLive => switch (this) {
    VehicleState.locked ||
    VehicleState.unlocked ||
    VehicleState.ready => true,
    _ => false,
  };

  /// 仪表已点亮（车辆已启动）：对应真车「解锁后仪表才点亮」。
  /// 上电→MCU 启动→（等待解锁）这一整段，仪表保持黑屏待机，不算点亮。
  bool get isAwake => switch (this) {
    VehicleState.unlocked || VehicleState.ready => true,
    _ => false,
  };

  /// 主流程条上的位置：断电 › 上电 › 未解锁 › 已解锁 › READY › 关机 › 拔电。
  int get flowIndex => switch (this) {
    VehicleState.off => 0,
    VehicleState.booting => 1,
    VehicleState.locked => 2,
    VehicleState.unlocked => 3,
    VehicleState.ready => 4,
    VehicleState.poweringOff => 5,
    VehicleState.poweredOff => 6,
    VehicleState.unsafeCut => 6,
  };

  /// 下一步该做什么（UI 提示 + 日志）。
  String get nextStep => switch (this) {
    VehicleState.off => '先上电；或直接刷卡唤醒（真车刷卡即上电解锁）',
    VehicleState.booting => 'MCU 启动 + 仪表就绪中（此阶段仪表黑屏待机属正常，点亮发生在解锁后）',
    VehicleState.locked => '仪表待机未点亮：刷卡解锁；或蓝牙连 TBOX 后长按 Ready；或 App 解锁；都没有则长按 Ready 输密码。解锁后仪表才点亮',
    VehicleState.unlocked => '长按 Ready 进入就绪；停车刷卡关机',
    VehicleState.ready => '停车：刷卡关机或长按 Ready 关机，等仪表断电后再拔电',
    VehicleState.poweringOff => '等 guest 报 Power down；超时可强制拔电',
    VehicleState.poweredOff => '此时才能拔电（正常下电已完成）',
    VehicleState.unsafeCut => '异常下电已记录；重新上电前建议确认车辆电力系统',
  };
}

/// 触发状态机的事件。
enum VehicleEvent {
  powerOn, // 上电
  bootReady, // 仪表首帧到达（启动完成）
  swipeCard, // 刷 NFC 卡
  appUnlock, // App 点解锁（TBOX 信号）
  longPressReady, // 长按 Ready
  pwUp, // 密码输入：上键（当前位 +1）
  pwDown, // 密码输入：下键（当前位 −1）
  pwSet, // 密码输入：SET 确认当前位并前进
  pwBack, // 密码输入：BACK 删除上一位
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
  VehicleMachine({this.pin = '000000'});

  /// 仿真密码。**不是**原厂密码；仅用于演示「无连接时密码解锁」这条路径。
  String pin;

  VehicleState state = VehicleState.off;

  /// 蓝牙是否已连上 TBOX（长按 Ready 解锁的前置条件）。
  bool bleConnected = false;

  /// TBOX 是否在线（App 解锁走 TBOX 信号，不要求蓝牙）。
  bool tboxOnline = false;

  /// 仪表密码输入界面是否激活（仅 locked 状态下有意义）。
  /// 真车：无 NFC/蓝牙连接时长按 Ready，仪表原生弹出密码输入，
  /// 由上/下选数字、SET 确认、BACK 删改；此处是客户端对仪表界面的镜像，
  /// 同时把上/下/SET/BACK 实时转发给仪表。
  bool passwordMode = false;

  /// 已确认的数字（按顺序）。
  List<int> pwEntered = <int>[];

  /// 当前正在选择的那一位（0–9）。
  int pwCursor = 0;

  int failedAttempts = 0;

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
    if (state == VehicleState.poweredOff) {
      // 仪表关机 ≠ 整车断电：真车必须先拔电源再重新上电。
      return _ignore(VehicleEvent.powerOn, '仪表已关机但整车仍接电：请先拔电，再重新上电');
    }
    _pendingUnlock = false;
    failedAttempts = 0;
    return _accept(
      VehicleEvent.powerOn,
      VehicleState.booting,
      VehicleEffect.startGuest,
      '上电：仪表开始启动',
    );
  }

  VehicleDecision _bootReady() {
    if (state != VehicleState.booting) {
      return _ignore(VehicleEvent.bootReady, '仪表启动完成事件被忽略（当前 ${state.label}）');
    }
    final unlock = _pendingUnlock;
    _pendingUnlock = false;
    failedAttempts = 0;
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
            '仪表启动完成 → 未解锁，等待刷卡 / Ready / App',
          );
  }

  VehicleDecision _swipeCard() {
    switch (state) {
      case VehicleState.off:
        // 真车刷卡本身就是唤醒动作：先上电，启动完成后直接解锁。
        _pendingUnlock = true;
        return _accept(
          VehicleEvent.swipeCard,
          VehicleState.booting,
          VehicleEffect.startGuest,
          '刷卡唤醒：上电并在仪表启动后直接解锁',
        );
      case VehicleState.booting:
        _pendingUnlock = true;
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
      case VehicleState.poweredOff:
        return _ignore(VehicleEvent.swipeCard, '仪表已关机但整车仍接电：请先拔电，再重新上电');
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
      case VehicleState.off:
        _pendingUnlock = true;
        return _accept(
          VehicleEvent.appUnlock,
          VehicleState.booting,
          VehicleEffect.startGuest,
          'App 解锁（TBOX 信号）：唤醒整车上电，启动后直接解锁',
        );
      case VehicleState.booting:
        _pendingUnlock = true;
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
      case VehicleState.poweredOff:
      case VehicleState.unsafeCut:
        return _ignore(VehicleEvent.appUnlock, '车辆正在/已经下电，App 解锁不适用');
    }
  }

  VehicleDecision _ready() {
    switch (state) {
      case VehicleState.locked:
        if (bleConnected) {
          failedAttempts = 0;
          return _accept(
            VehicleEvent.longPressReady,
            VehicleState.unlocked,
            VehicleEffect.none,
            '长按 Ready + 蓝牙已连 TBOX → 解锁',
          );
        }
        // 无连接：进入仪表原生密码输入界面（上/下/SET/BACK 驱动），
        // 并把上/下/SET/BACK 实时转发给仪表；不再用客户端弹窗假解锁。
        passwordMode = true;
        pwEntered = <int>[];
        pwCursor = 0;
        failedAttempts = 0;
        return VehicleDecision(
          event: VehicleEvent.longPressReady,
          accepted: false,
          state: state,
          message: '长按 Ready：无连接，仪表进入密码输入界面（上/下选数字，SET 确认，BACK 删改）',
          effect: VehicleEffect.promptPassword,
          hint: '仪表密码输入界面：上/下选数字，SET 确认，BACK 删改；输完与手机 App 密码一致即解锁',
        );
      case VehicleState.unlocked:
        return _accept(
          VehicleEvent.longPressReady,
          VehicleState.ready,
          VehicleEffect.none,
          '长按 Ready → 动力就绪（READY）',
        );
      case VehicleState.ready:
        return _accept(
          VehicleEvent.longPressReady,
          VehicleState.poweringOff,
          VehicleEffect.stopGuest,
          '长按 Ready 关机：等待仪表正常下电（下电完成后才能拔电）',
        );
      case VehicleState.off:
      case VehicleState.poweredOff:
      case VehicleState.unsafeCut:
        return _ignore(VehicleEvent.longPressReady, '整车未上电，长按 Ready 无效');
      case VehicleState.booting:
        return _ignore(VehicleEvent.longPressReady, '仪表启动中，请等画面出来');
      case VehicleState.poweringOff:
        return _ignore(VehicleEvent.longPressReady, '正在关机，请等待仪表断电');
    }
  }

  // 仪表原生密码输入：上/下选数字、SET 确认、BACK 删改。
  // 这些事件只在 passwordMode 有效；每次都如实地把上/下/SET/BACK 转给仪表。
  VehicleDecision _pwUp() {
    if (!passwordMode) return _ignore(VehicleEvent.pwUp, '当前不在密码输入界面');
    pwCursor = (pwCursor + 1) % 10;
    return _ignore(VehicleEvent.pwUp, '密码位 +1 → $pwCursor');
  }

  VehicleDecision _pwDown() {
    if (!passwordMode) return _ignore(VehicleEvent.pwDown, '当前不在密码输入界面');
    pwCursor = (pwCursor + 9) % 10;
    return _ignore(VehicleEvent.pwDown, '密码位 −1 → $pwCursor');
  }

  VehicleDecision _pwBack() {
    if (!passwordMode) return _ignore(VehicleEvent.pwBack, '当前不在密码输入界面');
    if (pwEntered.isEmpty) {
      return _ignore(VehicleEvent.pwBack, '已无可见位，无法删除');
    }
    pwEntered.removeLast();
    pwCursor = 0;
    return _ignore(VehicleEvent.pwBack, '删除上一位，已输入 ${pwEntered.length} 位');
  }

  VehicleDecision _pwSet() {
    if (!passwordMode) return _ignore(VehicleEvent.pwSet, '当前不在密码输入界面');
    pwEntered.add(pwCursor);
    pwCursor = 0;
    if (pwEntered.length < pin.length) {
      return _ignore(VehicleEvent.pwSet, '已输入 ${pwEntered.length}/${pin.length} 位');
    }
    if (pwEntered.join() == pin) {
      passwordMode = false;
      pwEntered = <int>[];
      failedAttempts = 0;
      return _accept(
        VehicleEvent.pwSet,
        VehicleState.unlocked,
        VehicleEffect.none,
        '密码正确 → 解锁',
      );
    }
    failedAttempts++;
    pwEntered = <int>[];
    pwCursor = 0;
    return VehicleDecision(
      event: VehicleEvent.pwSet,
      accepted: false,
      state: state,
      message: '密码错误（第 $failedAttempts 次）',
      effect: VehicleEffect.promptPassword,
      hint: '密码错误（第 $failedAttempts 次），请重新输入',
    );
  }

  VehicleDecision _shutdown(String source) {
    switch (state) {
      case VehicleState.locked:
      case VehicleState.unlocked:
      case VehicleState.ready:
        return _accept(
          VehicleEvent.shutdownRequest,
          VehicleState.poweringOff,
          VehicleEffect.stopGuest,
          '$source：正常关机，等待仪表下电（下电完成后才能拔电）',
        );
      case VehicleState.booting:
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
      '仪表已正常关机（Power down）→ 现在可以拔电',
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
      return _accept(
        VehicleEvent.fault,
        VehicleState.off,
        VehicleEffect.none,
        '上电失败：仪表未能启动',
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
    pwEntered = <int>[];
    pwCursor = 0;
    failedAttempts = 0;
    bleConnected = false;
    tboxOnline = false;
  }
}
