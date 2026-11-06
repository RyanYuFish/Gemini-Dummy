// MCU 侧「开机密码」会话（Power_On_Passwd / prop 0x21709701）。
//
// 逆向结论（docs/EMULATION.md §49）：
//   * 仪表的密码界面是固件自己的 Qt 类 `PasswordUL` / `PasswordULFB70`，
//     由 `ShowPasswordUI(QWidget*)` 创建，资源是 `://AE4i/passwordbg.png`、
//     `密码解锁动画.png` 等内嵌素材；**界面必须由固件自己画**。
//   * AE5I 的 `PasswordULFB70::VertifyPasswd(QString)` 比较固件缓存的
//     4 位密码；验证成功后通过 `0x21709701` 状态帧通知 MCU 仿真端。
//     另保留 ASCII 提交格式的模型兼容分支，当前 AE5I 不依赖它。
//   * MCU → 仪表方向的属性同样是 6 字节：
//       [0..3] 4 位密码（ASCII）  [4] 状态位  [5] 保留
//       bit6 0x40 = gointo_passwd_ui      （请求进入原生密码界面）
//       bit4 0x10 = check_passwd_success  （校验通过）
//       bit3 0x08 = tryNumber_error_lock_notify（错误次数/锁定）
//       bit5 0x20 = shutdown_notify
//       bit7 0x80 = verify_status         （仪表提交校验请求）
//
// 因此客户端**不保存任何可绘制的密码界面状态**：上/下/SET/BACK 只做两件事
// ——原样透传给仪表（由固件 UI 自己渲染和校验）。这样
// 界面要么由固件画，要么根本不存在，杜绝任何「客户端镜像/自绘」。
//
// 纯 Dart，无 Flutter 依赖，便于单测与端到端脚本复用。

/// 把手上驱动密码输入的四个键（真车 keymap：上 0xd2 / 下 0xd3 / SET 0xd4 / BACK 0xd5）。
enum PasswordKey { up, down, set, back }

/// 一次按键/提交后 MCU 的判定。
enum PasswordResult {
  /// 还没凑够 4 位，或会话未激活。
  pending,

  /// 校验通过：MCU 发 check_passwd_success + 解锁通知。
  accepted,

  /// 校验失败：MCU 发 tryNumber_error_lock_notify，清空重来。
  rejected,

  /// 固件要求关机：原生密码页长按 BACK 或右上角倒计时归零时，
  /// `PasswordUL::shutDown()` 会把 `byte[4] |= 0x20`（shutdown_notify）
  /// 发上来。MCU 收到后必须走正常下电，而不是继续等密码。
  shutdown,
}

/// `Power_On_Passwd` 6 字节状态位。
class PowerOnPasswdBit {
  static const int goIntoUi = 0x40;
  static const int checkSuccess = 0x10;
  static const int tryNumberError = 0x08;
  static const int shutdownNotify = 0x20;
  static const int verifyStatus = 0x80;
}

/// GD32/MCU 侧保存的开机密码与输入会话。
class McuPassword {
  McuPassword({this.pin = defaultPin});

  /// 固件 `VertifyPasswd(QString)` 只接受长度 4 的输入，密码也必须是 4 位。
  static const int pinLength = 4;
  static const String defaultPin = '0000';

  /// 真车里由手机 App 设置并存进 MCU；仿真里可改，但**没有客户端编辑界面**。
  String pin;

  /// 是否处于「等待密码」会话（长按 Ready 且无 NFC/蓝牙/TBOX 时由 MCU 开启）。
  bool active = false;

  /// 已确认的数字（MCU 内部状态，不用于任何 UI 绘制）。
  final List<int> digits = <int>[];

  /// 当前待确认位的数字（0–9）。
  int cursor = 0;

  /// 连续错误次数（对应固件 `WriteErrorTimes` / `ReadErrorTimes`）。
  int failures = 0;

  /// 开始一次密码会话。
  void begin() {
    active = true;
    digits.clear();
    cursor = 0;
  }

  /// 取消会话（刷卡 / 蓝牙 / App 解锁，或下电）。
  void cancel() {
    active = false;
    digits.clear();
    cursor = 0;
  }

  /// 把一次把手按键喂给 MCU 侧会话。返回是否已解锁。
  PasswordResult key(PasswordKey k) {
    if (!active) return PasswordResult.pending;
    switch (k) {
      case PasswordKey.up:
        cursor = (cursor + 1) % 10;
        return PasswordResult.pending;
      case PasswordKey.down:
        cursor = (cursor + 9) % 10;
        return PasswordResult.pending;
      case PasswordKey.back:
        if (digits.isNotEmpty) {
          digits.removeLast();
          cursor = 0;
        }
        return PasswordResult.pending;
      case PasswordKey.set:
        digits.add(cursor);
        cursor = 0;
        if (digits.length < pinLength) return PasswordResult.pending;
        return _check(digits.join());
    }
  }

  /// 固件 `PasswordUL` 直接通过 `mcucom_tx_power_on_passwd` 提交 4 位密码时，
  /// MCU 侧校验这一份（不依赖客户端按键镜像）。[payload] 是完整 6 字节结构。
  PasswordResult verifyFrame(List<int> payload) {
    if (payload.length != 6) return PasswordResult.pending;
    final bits = payload[4];
    // ★ 关机通知优先级最高：原生密码页的长按 BACK（KeyDelegate 3 s）与
    //   右上角倒计时（10 步 × 1 s）最终都走 `PasswordUL::shutDown()`，
    //   把 byte[4] |= 0x20 发给 MCU。此时 payload 里的 4 位数字无意义，
    //   不能拿去比对密码。收到就结束会话，由控制器执行正常下电。
    if (active && (bits & PowerOnPasswdBit.shutdownNotify) != 0) {
      cancel();
      return PasswordResult.shutdown;
    }
    if (!active) return PasswordResult.pending;
    // 当前 AE5I 的 tx 函数 @0x3ec2c 将前四字节清零。原生 PasswordUL
    // 可在 Qt 内比较 MCU 缓存密码，成功后 mcuStart() 上报 wire bit4。
    // 仅接纳活动会话中 guest 返回的纯成功通知，空帧不能解锁。
    if (payload.sublist(0, 4).every((v) => v == 0) &&
        bits == PowerOnPasswdBit.checkSuccess) {
      failures = 0;
      cancel();
      return PasswordResult.accepted;
    }
    // bit6 是 MCU→仪表方向的「进入界面」，不是仪表提交。
    if ((bits & PowerOnPasswdBit.goIntoUi) != 0) {
      return PasswordResult.pending;
    }
    final chars = payload.sublist(0, 4);
    final digits = chars
        .map((b) => (b >= 0x30 && b <= 0x39) ? b - 0x30 : -1)
        .toList();
    if (digits.contains(-1)) return PasswordResult.pending;
    return _check(digits.join());
  }

  PasswordResult _check(String entered) {
    digits.clear();
    cursor = 0;
    if (entered == pin) {
      failures = 0;
      active = false;
      return PasswordResult.accepted;
    }
    failures++;
    return PasswordResult.rejected;
  }
}
