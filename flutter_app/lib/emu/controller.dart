// QEMU 子进程控制：启动、串口桥、monitor 命令、抓帧。
//
// 前端从不通过 HTTP 与后端通信 —— 它直接持有 QEMU 进程：
//   guest ttyS0  → QEMU stdout（-serial stdio）
//   画面        → QEMU guest framebuffer 快照
//   按键        → ttyS1 CFCP 按下/释放帧

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import 'machine.dart';
import 'cfcp.dart';
import 'dash_up.dart';
import 'gd32.dart';
import 'keys.dart';
import 'mcu.dart';
import 'paths.dart';
import 'ppm.dart';
import 'spvd.dart';
import 'vehicle.dart';

// ---------------------------------------------------------------- serial bridge

const int kSerialBridgePort = 9001;

/// 把 guest 串口镜像给外部终端（picocom / nc / NyaTerm）。
///
/// QEMU 独占 `-serial stdio`，所以本应用充当 broker：guest 输出既进日志也广播给
/// 每个 TCP 客户端，客户端敲的字节写回 QEMU stdin（即直接进 guest console）。
class SerialBridge {
  final int port;
  ServerSocket? _server;
  final _clients = <Socket>{};

  final clients = ValueNotifier<int>(0);
  final listening = ValueNotifier<bool>(false);
  final error = ValueNotifier<String>('');

  void Function(String)? onInput;

  SerialBridge({this.port = kSerialBridgePort});

  String get address => 'tcp://127.0.0.1:${_server?.port ?? port}';

  Future<void> start() async {
    if (_server != null) return;
    try {
      final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
      _server = s;
      listening.value = true;
      error.value = '';
      s.listen((socket) {
        _clients.add(socket);
        clients.value = _clients.length;
        socket.write(
          '\r\n*** AE5I serial bridge — guest ttyS0@921600 (1024x600 panel) ***\r\n',
        );
        socket.listen(
          (data) => onInput?.call(utf8.decode(data, allowMalformed: true)),
          onDone: () => _drop(socket),
          onError: (_) => _drop(socket),
          cancelOnError: true,
        );
      });
    } catch (e) {
      listening.value = false;
      error.value = '$e';
    }
  }

  void _drop(Socket s) {
    _clients.remove(s);
    clients.value = _clients.length;
  }

  void feed(String data) {
    for (final c in _clients.toList()) {
      try {
        c.write(data);
      } catch (_) {
        _drop(c);
      }
    }
  }

  Future<void> stop() async {
    for (final c in _clients.toList()) {
      try {
        c.destroy();
      } catch (_) {}
    }
    _clients.clear();
    clients.value = 0;
    await _server?.close();
    _server = null;
    listening.value = false;
  }
}

// ---------------------------------------------------------------- log

enum LogKind { qemu, serial, monitor, app, mcu }

class LogLine {
  final DateTime t;
  final LogKind kind;
  final String text;
  int count = 1;
  LogLine(this.kind, this.text) : t = DateTime.now();
}

// ---------------------------------------------------------------- controller

class QemuController {
  Process? _proc;
  Socket? _mon;
  Socket? _cfcp;

  /// CFCP 入站字节缓冲（guest → 客户端）。TCP 会随意分段，必须自行拼帧。
  final _cfcpRx = <int>[];

  /// 诊断开关：`AE5I_CFCP_TRACE=1` 时把入站原始字节逐段打进日志。
  static final bool _cfcpTrace = Platform.environment['AE5I_CFCP_TRACE'] == '1';

  /// 入站帧计数（诊断用）。
  int _cfcpRxFrames = 0;

  /// 已回给对端的 ACK 数。
  int _cfcpAckSent = 0;

  /// 对端推来的属性：prop → 最近值。
  final _peerProps = <int, int>{};

  /// guest（SoC）广播给我们的仪表状态快照。
  ///
  /// 我们在 QEMU 里扮演 MCU，guest 是 SoC：它把仪表状态（灯态位图/档位/状态/
  /// 心跳…）广播到 ttyS1，这份快照就是**集群真实状态**的观测口。
  /// 方向更正见 gd32.dart 文件头与 EMULATION.md §29。
  final clusterState = ValueNotifier(const ClusterPeerState());

  Future<void> _keyQueue = Future.value();
  Timer? _timer;
  Timer? _tick;

  LaunchSpec? _spec;

  final log = StreamController<LogLine>.broadcast();
  final frames = StreamController<ui.Image>.broadcast();
  final running = ValueNotifier<bool>(false);
  final pid = ValueNotifier<int?>(null);
  final fps = ValueNotifier<double>(0);
  final uptime = ValueNotifier<Duration>(Duration.zero);
  final lastCmd = ValueNotifier<String>('—');
  final vdisk = ValueNotifier<SpvdImage?>(null);
  final kernel = ValueNotifier<KernelImage?>(null);
  final bridge = SerialBridge(port: 0);
  final lastError = ValueNotifier<String?>(null);
  final status = ValueNotifier<String>('未上电');
  final vehicleStatus = ValueNotifier<String>('未认证（固件状态未知）');

  /// 整车状态机：真车流程（上电 → 解锁 → Ready → 关机 → 拔电）的唯一真值源。
  /// 它只驱动客户端与 QEMU 生命周期，不伪造车辆总线报文。
  final vehicle = VehicleMachine();
  final vehicleState = ValueNotifier<VehicleState>(VehicleState.off);
  final bleConnected = ValueNotifier<bool>(false);
  final tboxOnline = ValueNotifier<bool>(false);

  /// 模拟 GD32 MCU 的车身功能（转向 / 双闪 / 远光 / 定速 / 档位 …）。
  /// 只在客户端生效：仪表画面不会因此改变，理由见 emu/mcu.dart。
  final mcu = McuSim();
  final mcuEvents = ValueNotifier<int>(0);

  /// 仪表密码盘状态变更通知（上/下/SET/BACK 改数字时 +1），驱动密码 HUD 重绘。
  final pwNotifier = ValueNotifier<int>(0);

  /// 仪表画面点亮状态：首帧到达但仍是纯黑时 = false；出现非黑像素后 = true。
  /// UI 用它给出诚实提示（黑屏期 / 局部页面），避免把"预期内的黑屏"误判为故障。
  final displayLit = ValueNotifier<bool>(false);

  /// 当前帧非黑像素占比（0.0–1.0），由 [_grab] 每帧廉价扫描得出。
  final displayPaintedPct = ValueNotifier<double>(0.0);

  /// 开机动画阶段（模型还没把画面交给 guest）。true 时画面上的非黑像素来自
  /// 原厂 logo 动画，不能算"仪表已点亮"。
  final animating = ValueNotifier<bool>(false);
  bool _animHoldOver = true;

  /// 本次（开机/关机）动画的开始时刻。兜底超时按它算而不是按上电时刻——
  /// 解锁可能发生在上电 15 s 之后，用上电时刻会把刚开始的动画立刻判超时。
  DateTime? _animStartedAt;

  /// 唤醒触发文件路径：解锁时创建，模型据此重放开机动画（真车「解锁后仪表点亮」）。
  String? _wakeFile;
  bool _wakeFired = false;

  /// 关机动画触发文件路径：下电前创建，模型据此倒放 logo。
  String? _shutdownWakeFile;
  bool _shutdownAnimSent = false;

  /// MCU 上电日志序列定时器（模拟 GD32 启动 / 认证轮询的串口输出）。
  Timer? _mcuTimer;

  /// MCU 对端：按 EMULATION.md §41 三段式进场喂 KL15 / 解锁 / 挡位 / 全量
  /// 车辆数据，让固件自己画出 P 档主界面。上电即启动，不再等用户解锁。
  DashUpFeeder? _dashUp;

  /// 进场序列已跑完（画面确实由固件点亮），供 displayLit 诚实指示。
  bool _clusterEntered = false;

  /// MCU 遥测数据源：所有上屏数值的唯一真值源，由固件渲染，不重绘。
  final telemetry = DashTelemetry();

  bool _shutdownRequested = false;
  bool _shutdownCommandSent = false;
  bool _consoleReady = false;
  Timer? _shutdownTimer;
  String _serialTail = '';

  DateTime? _startedAt;
  int _frameCount = 0;
  int _frameErrors = 0;
  bool _busy = false;
  bool _starting = false;
  bool _disposed = false;
  bool _forceStopping = false;
  Directory? _sessionDir;

  /// 画面在变时 12 ms 取一帧；连续 [_stillLimit] 帧完全没变才降到 300 ms。
  ///
  /// 这个值直接决定动画观感，实测（`test/anim_quality.dart`，真实 QEMU，
  /// 开机 logo 动画窗口）：
  ///
  /// | 客户端轮询 | 模型发布 | 到达帧率 | 帧间隔 p50 / p95 |
  /// |---|---|---|---|
  /// | 40 ms | 16 ms | 15.5 fps | 77 / 83 ms |
  /// | 20 ms | 8 ms  | 32.5 fps | 34 / 42 ms |
  /// | **12 ms** | **8 ms** | **55.7 fps** | **16 / 26 ms** |
  ///
  /// 原厂 logo 是 1024x600@60fps，12 ms 轮询已经能跟上它的原生节奏
  /// （p50=16 ms ≈ 一帧）。**瓶颈从来不是客户端解码**（换成零拷贝的原始
  /// BGRA 通道实测毫无提升），而是轮询间隔本身。
  static const Duration _fastGrab = Duration(milliseconds: 12);
  static const Duration _slowGrab = Duration(milliseconds: 300);

  /// 连续多少帧「逐像素完全一致」才认定画面静止、降速。
  static const int _stillLimit = 8;

  /// 连续「画面未变」的帧数；任何变化都清零。
  int _stillGrabs = 0;

  /// 上一帧的跨步签名（用于判断画面是否在变）。
  int _lastGrabSig = 0;

  /// 距上一次抓帧的间隔。
  DateTime _lastGrab = DateTime.fromMillisecondsSinceEpoch(0);

  final StringBuffer _partial = StringBuffer();

  LaunchSpec? get spec => _spec;
  bool get captureEnabled => _spec?.framebufferReady ?? false;

  /// 当前命令行（未启动时为空）。
  List<String> get cmdline => _spec?.argv() ?? const [];

  String get qemuBin => _spec?.qemuBin ?? LabPaths.customQemu;

  void _emitSerial(String s) {
    if (s.isEmpty || _disposed) return;
    _serialTail = (_serialTail + s);
    if (_serialTail.length > 2048) {
      _serialTail = _serialTail.substring(_serialTail.length - 2048);
    }
    if (RegExp(r'root@[A-Za-z0-9_.-]+:[^\r\n]*#').hasMatch(_serialTail)) {
      _consoleReady = true;
      _sendShutdownCommand();
    }
    if (_shutdownRequested &&
        RegExp(
          r'Power down|System halted',
          caseSensitive: false,
        ).hasMatch(_serialTail)) {
      _shutdownTimer?.cancel();
      _dispatch(VehicleEvent.guestPowerDown);
      _emit(LogKind.app, 'guest 已报告关机/停机完成；结束本次 QEMU 会话');
      _monitor('quit');
    }
    _partial.write(s);
    final buf = _partial.toString();
    final cut = buf.lastIndexOf('\n');
    if (cut < 0) {
      if (buf.length > 65536) _partial.clear();
      return;
    }
    _partial
      ..clear()
      ..write(buf.substring(cut + 1));
    for (final line in buf.substring(0, cut).split('\n')) {
      final clean = _stripAnsi(line);
      if (clean.trim().isEmpty) continue;
      log.add(LogLine(LogKind.serial, clean));
    }
  }

  static final _ansi = RegExp(
    r'\x1B\[[0-9;?]*[A-Za-z]|\x1B[()][A-Z0-9]|\x1B[=>]|\r',
  );
  static String _stripAnsi(String s) => s.replaceAll(_ansi, '');

  void _emit(LogKind k, String s) {
    if (s.isEmpty || _disposed) return;
    for (final line in const LineSplitter().convert(s)) {
      final clean = _stripAnsi(line);
      if (clean.trim().isEmpty) continue;
      log.add(LogLine(k, clean));
    }
  }

  /// 推进整车状态机，并把结果同步到 UI 可见的 ValueNotifier。
  VehicleDecision _dispatch(VehicleEvent event, {String? pinInput}) {
    final prev = vehicle.state;
    final d = vehicle.dispatch(event, pinInput: pinInput);
    vehicleState.value = vehicle.state;
    vehicleStatus.value = vehicle.state.label;
    if (d.message.isNotEmpty) _emit(LogKind.app, d.message);
    // 进入「已解锁」= 真车解锁并启动车辆；此刻仪表才点亮（重放开机动画）。
    if (vehicle.state == VehicleState.unlocked &&
        prev != VehicleState.unlocked) {
      _fireWake();
    }
    return d;
  }

  /// 解锁瞬间：通知模型重放开机动画（创建唤醒触发文件），并记一条 MCU 授权日志。
  void _fireWake() {
    _emit(
      LogKind.mcu,
      'MCU: key authenticated — release cluster wake (replay logo)',
    );
    if (_wakeFile != null && !_wakeFired) {
      _wakeFired = true;
      try {
        File(_wakeFile!).writeAsStringSync('unlocked\n');
      } catch (e) {
        _emit(LogKind.app, '唤醒触发文件写入失败：$e');
      }
    }
    // MCU 对端已在上电时启动（真车 MCU 与仪表同电源上电），这里不重复
    // 发基线帧、也不重写挡位：反复写 gear 会让 slot_delayUpdateGear 重摆顶部
    // DRL/ECO，把图标叠成双份（EMULATION.md §41）。
  }

  /// 模拟 GD32 MCU 上电启动与各外设初始化，把代表性日志流进日志面板，
  /// 对应真车「上电 ⇒ MCU 启动（此刻串口开始有 mcu 相关日志输出）」。
  /// 这是客户端对 MCU 行为的仿真（与 SP_IPC_STUB 同一思路），并非运行真实固件。
  void _emitMcuBoot() {
    const lines = <String>[
      'MCU GD32F303 reset vector @ 0x08000000',
      'MCU clock: HSE 8MHz → PLL 120MHz locked',
      'MCU CAN0 init: 500kbps, acceptance filters loaded',
      'MCU NFC (PN532) reader online, polling 13.56MHz',
      'MCU BLE stack idle — awaiting TBOX / Phone link',
      'MCU auth: no key present, enter low-power poll',
      'MCU CFCP link to cluster (ttyS1) up @ 115200',
    ];
    var i = 0;
    void step() {
      if (_disposed || !running.value || i >= lines.length) return;
      _emit(LogKind.mcu, lines[i]);
      i++;
      if (i < lines.length) {
        // 轻微抖动，避免像机器刷屏。
        final delay = 200 + (i * 70) % 220;
        _mcuTimer = Timer(Duration(milliseconds: delay), step);
      }
    }

    _mcuTimer = Timer(const Duration(milliseconds: 150), step);
  }

  /// 推进状态机并执行它要求的副作用（启动/关机由控制器负责）。
  Future<VehicleDecision> _apply(
    VehicleEvent event, {
    String? pinInput,
    String? spvdPath,
  }) async {
    final d = _dispatch(event, pinInput: pinInput);
    switch (d.effect) {
      case VehicleEffect.startGuest:
        await start(spvdPath: spvdPath);
        if (!running.value && !_disposed) {
          return _dispatch(VehicleEvent.fault);
        }
        break;
      case VehicleEffect.stopGuest:
        await _gracefulShutdown();
        break;
      case VehicleEffect.none:
      case VehicleEffect.promptPassword:
      case VehicleEffect.confirmUnsafeCut:
        break;
    }
    return d;
  }

  // ------------------------------------------------------------ 整车流程入口

  /// 上电：启动 QEMU 仪表（真车「整车通电、仪表点亮」）。
  Future<VehicleDecision> powerOn({String? spvdPath}) =>
      _apply(VehicleEvent.powerOn, spvdPath: spvdPath);

  /// 刷 NFC 卡：未上电时先上电并在启动后解锁；已解锁/Ready 时关机。
  Future<VehicleDecision> swipeCard({String? spvdPath}) =>
      _apply(VehicleEvent.swipeCard, spvdPath: spvdPath);

  /// App 解锁（TBOX 信号）。要求 [tboxOnline]。
  Future<VehicleDecision> appUnlock({String? spvdPath}) =>
      _apply(VehicleEvent.appUnlock, spvdPath: spvdPath);

  /// 长按 Ready：未解锁时按连接方式解锁；已解锁进 Ready；Ready 时关机。
  /// 无连接时长按 Ready 会进入仪表原生密码输入界面（见 [pwUp] 等）。
  Future<VehicleDecision> longPressReady({String? spvdPath}) =>
      _apply(VehicleEvent.longPressReady, spvdPath: spvdPath);

  /// 仪表密码输入：上键（当前位数字 +1）。同时把上键真实转发给仪表。
  Future<VehicleDecision> pwUp() => _pwKey(VehicleEvent.pwUp, '上', 0xd2);

  /// 仪表密码输入：下键（当前位数字 −1）。同时把下键真实转发给仪表。
  Future<VehicleDecision> pwDown() => _pwKey(VehicleEvent.pwDown, '下', 0xd3);

  /// 仪表密码输入：SET 确认当前位并前进。同时把 SET 真实转发给仪表。
  Future<VehicleDecision> pwSet() => _pwKey(VehicleEvent.pwSet, 'SET', 0xd4);

  /// 仪表密码输入：BACK 删除上一位。同时把 BACK 真实转发给仪表。
  Future<VehicleDecision> pwBack() => _pwKey(VehicleEvent.pwBack, 'BACK', 0xd5);

  Future<VehicleDecision> _pwKey(VehicleEvent e, String label, int code) async {
    final d = _dispatch(e);
    pwNotifier.value++;
    _forwardKeyTap(label, code);
    return d;
  }

  /// 把密码盘的按键如实转发给仪表（真车上/下/SET/BACK 本就发给仪表）。
  void _forwardKeyTap(String label, int code) {
    if (!running.value || _disposed) return;
    sendKeyEvent(label, code, true);
    Future<void>.delayed(const Duration(milliseconds: 40), () {
      if (!_disposed) sendKeyEvent(label, code, false);
    });
  }

  /// 把手按键总入口：仪表键发 CFCP 帧，MCU 键走 [mcu] 模型。
  ///
  /// 返回给 UI 用的提示（null = 无提示）。分开处理的原因见 emu/keys.dart 顶部：
  /// 设备的 keymap.data 只登记了 11 个 KeyID，其余键在真车上由 GD32 执行。
  Future<String?> pressInstrumentKey(
    InstrumentKey k, {
    bool long = false,
  }) async {
    final code = k.code;
    if (code != null) {
      if (!running.value) return '仪表未运行，无法发送「${k.label}」';
      await sendKeyEvent(k.label, code, true);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await sendKeyEvent(k.label, code, false);
      final action = ClusterKeys.actionName(code);
      return action == null
          ? '「${k.label}」已发送 CFCP 0x${code.toRadixString(16)}'
                '（keymap 有映射但 Launcher 未命名动作）'
          : '「${k.label}」→ 仪表 $action';
    }
    final fn = k.mcu;
    if (fn == null) return null;
    final r = mcu.press(fn, long: long);
    for (final line in r.lines) {
      _emit(LogKind.mcu, line);
    }
    mcuEvents.value++;
    // 车身状态变化时发送实验灯态帧；加减拨杆尚无映射，不注入猜测档位。
    if (r.stateChanged) _emitMcuState();
    return r.lines.isEmpty ? null : r.lines.last;
  }

  /// 拔电：正常下电之后才允许；仍通电时返回 confirmUnsafeCut 交给 UI 二次确认。
  Future<VehicleDecision> unplugPower() async {
    final d = _dispatch(VehicleEvent.unplug);
    if (d.accepted) await _finalizeUnplug();
    return d;
  }

  /// 用户已确认「未关机直接拔电」：结束 QEMU 并记录异常下电。
  Future<VehicleDecision> confirmUnsafeCut() async {
    final d = _dispatch(VehicleEvent.forceCut);
    _emit(LogKind.app, '用户确认异常下电：直接结束 QEMU 进程');
    _emit(LogKind.mcu, 'MCU: power-down (unsafe cut) — cluster held dark');
    _forceStopping = true;
    try {
      _mon?.destroy();
    } catch (_) {}
    _mon = null;
    _cfcp?.destroy();
    _cfcp = null;
    _proc?.kill();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    _cleanup();
    return d;
  }

  void setBleConnected(bool v) {
    vehicle.bleConnected = v;
    bleConnected.value = v;
    _emit(
      LogKind.app,
      v ? '蓝牙已连接 TBOX：长按 Ready 可解锁' : '蓝牙已断开 TBOX：长按 Ready 转为密码解锁',
    );
  }

  void setTboxOnline(bool v) {
    vehicle.tboxOnline = v;
    tboxOnline.value = v;
    _emit(LogKind.app, v ? 'TBOX 在线：App 解锁可用' : 'TBOX 离线：App 解锁不可用');
  }

  void setSimPin(String v) {
    vehicle.pin = v;
    _emit(LogKind.app, '仿真解锁密码已更新（演示用，不是原厂密码）');
  }

  Future<void> start({String? spvdPath, String? kernelPath}) async {
    if (running.value || _starting || _disposed) return;
    // 低层启动入口：若整车尚未上电，先补一次上电迁移，保证状态机与进程一致。
    // 已关机但未拔电时状态机会拒绝，这里必须跟着拒绝，否则进程与状态会脱节。
    if (!vehicle.state.isPowered) {
      final d = _dispatch(VehicleEvent.powerOn);
      if (d.effect != VehicleEffect.startGuest) return;
    }
    _starting = true;
    _forceStopping = false;
    lastError.value = null;
    status.value = '正在上电 · 预检';
    try {
      _sessionDir = Directory.systemTemp.createTempSync('ae5i-session-');
      final dir = _sessionDir!.path;
      _emit(LogKind.app, '会话目录：$dir');
      final prep = BootPreparation.prepare(
        spvdPath: spvdPath,
        kernelPath: kernelPath,
        kernelOutputPath: '$dir/kernel.bin',
      );
      for (final step in prep.steps) {
        _emit(LogKind.app, step);
      }
      vdisk.value = prep.spvd;
      kernel.value = prep.kernel;
      if (!prep.ok) throw StateError(prep.error!);
      // Let the OS choose a free port instead of colliding with another client.
      final reservation = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final port = reservation.port;
      await reservation.close();
      if (_disposed || !_starting) return;
      final base = prep.spec!;
      final spec = LaunchSpec(
        qemuBin: base.qemuBin,
        kernel: base.kernel,
        spvd: base.spvd,
        append: base.append,
        cfcpPort: port,
        monitorSock: '$dir/monitor.sock',
        framePath: '$dir/frame.ppm',
        bootAnim: base.bootAnim,
        // 有开机动画时，让模型延迟到解锁才重放（真车解锁后仪表才点亮）。
        wakeFile: base.bootAnim != null ? '$dir/wake' : null,
        // 关机动画：下电前创建触发文件，模型倒放 logo 后再由 guest poweroff 变黑。
        shutdownWakeFile: base.bootAnim != null ? '$dir/shutdown-wake' : null,
        extraEnv: base.extraEnv,
      );
      _spec = spec;
      _partial.clear();
      _serialTail = '';
      _consoleReady = false;
      _shutdownRequested = false;
      _shutdownCommandSent = false;
      _emit(LogKind.qemu, spec.shellLine());
      final proc = await Process.start(
        spec.qemuBin,
        spec.argv(),
        workingDirectory: LabPaths.lab,
        environment: {...Platform.environment, ...spec.env()},
      );
      if (_disposed || !_starting) {
        proc.kill();
        return;
      }
      _proc = proc;
      pid.value = proc.pid;
      running.value = true;
      status.value = '内核启动中 · 等待画面';
      _startedAt = DateTime.now();
      _frameCount = 0;
      _frameErrors = 0;
      _lastGrab = DateTime.fromMillisecondsSinceEpoch(0);
      // 开机动画三态：
      //  - 无动画：直接算"已交还"（_animHoldOver=true，animating=false）
      //  - 有动画且上电即播（无 wakeFile）：立即 animating=true
      //  - 有动画且延迟（有 wakeFile）：等待解锁时模型才重放，此刻尚未开始
      final hasAnim = spec.bootAnim != null;
      final deferred = spec.wakeFile != null;
      _animHoldOver = !hasAnim || !deferred;
      animating.value = hasAnim && !deferred;
      _wakeFile = spec.wakeFile;
      _wakeFired = false;
      _shutdownWakeFile = spec.shutdownWakeFile;
      _shutdownAnimSent = false;
      displayLit.value = false;
      displayPaintedPct.value = 0.0;
      fps.value = 0;
      uptime.value = Duration.zero;
      // 上电后模拟 MCU 启动串口日志（真车：上电⇒MCU 启动，串口开始有 MCU 日志）。
      _emitMcuBoot();
      // 真车 MCU 与仪表同电源上电，所以 CFCP 链路在**启动阶段**就应存在：
      // 早连能收下 guest 开机期间推的属性帧并及时 ACK（否则这些帧会被内核
      // 重传 3 次后丢弃，见 _handleCfcpFrame 注释）。
      _connectCfcpEarly();
      // ★ 上电即开始喂 MCU 数据：KL15 点亮 → 解锁通知 → 三段式进场 → P 档。
      //   旧版本只在「用户解锁」后发 11-02 的旧基线帧（版本/握手/心跳），
      //   既没有 KL15 也没有 synchronization_status / vehicle_info2，
      //   固件因此一直停在黑屏 / 待机统计页。见 EMULATION.md §41。
      _startDashUp();
      final errors = StringBuffer();
      proc.stdout.transform(const Utf8Decoder(allowMalformed: true)).listen((
        s,
      ) {
        _emitSerial(s);
        bridge.feed(s);
      }, onDone: () => _emit(LogKind.serial, '· guest serial closed ·'));
      proc.stderr.transform(const Utf8Decoder(allowMalformed: true)).listen((
        s,
      ) {
        if (errors.length < 8192) errors.write(s);
        // 模型把"动画交给 guest"这件事写在 stderr 上（BOOTANIM: guest took ...）。
        // 在那之前的非黑像素都来自开机动画，不能当成"仪表画面已点亮"，
        // 否则状态机会在 logo 阶段就跳到 bootReady。
        if (s.contains('BOOTANIM: guest took') ||
            s.contains('BOOTANIM: restored pre-anim') ||
            s.contains('BOOTANIM: frame corrupt') ||
            s.contains('BOOTANIM: no guest paint') ||
            s.contains('BOOTANIM: stopped at')) {
          _animHoldOver = true;
          _animStartedAt = null;
          animating.value = false;
        } else if (s.contains('BOOTANIM:') &&
            !s.contains('deferred') &&
            !s.contains('guest took') &&
            !s.contains('restored pre-anim') &&
            !s.contains('frame corrupt') &&
            !s.contains('no guest paint') &&
            !s.contains('stopped at')) {
          // 模型（重）开始播放开机动画（上电即播，或解锁后唤醒重放）。
          _animHoldOver = false;
          _animStartedAt ??= DateTime.now();
          animating.value = true;
        }
        _emit(LogKind.qemu, s);
      });
      bridge.onInput = (data) => proc.stdin.write(data);
      await bridge.start();
      _emit(
        LogKind.app,
        bridge.listening.value
            ? '串口桥已监听 ${bridge.address}'
            : '串口桥失败：${bridge.error.value}',
      );
      proc.exitCode.then((code) {
        if (_disposed || !identical(_proc, proc)) return;
        _emit(LogKind.app, 'QEMU 退出，code=$code');
        // 正常关机路径已先收到 Power down 并迁到 poweredOff；这里仍在「有电」
        // 说明进程是异常结束的，按等效异常断电记录。
        if (vehicle.state.isPowered) _dispatch(VehicleEvent.fault);
        if (code != 0 && !_forceStopping) {
          lastError.value = 'QEMU 退出码 $code：${errors.toString().trim()}';
        }
        status.value = vehicle.state.label;
        bridge.stop();
        _cleanup();
      });
      for (var i = 0; i < 60; i++) {
        if (!identical(_proc, proc)) return;
        if (File(spec.monitorSock).existsSync()) break;
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
      if (!identical(_proc, proc)) return;
      await _connectMonitor();
      // 90 ms 轮询 + 内部节流：开机动画要跟帧，UI 稳定后再降到 900 ms。
      _timer = Timer.periodic(_fastGrab, (_) => _tickGrab());
      _tick = Timer.periodic(const Duration(seconds: 1), (_) {
        if (_startedAt != null) {
          uptime.value = DateTime.now().difference(_startedAt!);
        }
        fps.value = _frameCount.toDouble();
        _frameCount = 0;
      });
    } catch (e) {
      if (!_disposed) {
        lastError.value = '$e';
        status.value = '上电失败';
        _emit(LogKind.app, '上电失败：$e');
        _proc?.kill();
        await bridge.stop();
        _dispatch(VehicleEvent.fault);
        _cleanup();
      }
    } finally {
      _starting = false;
    }
  }

  Future<void> _connectMonitor() async {
    try {
      final s = await Socket.connect(
        InternetAddress(_spec!.monitorSock, type: InternetAddressType.unix),
        0,
      );
      _mon = s;
      s.listen((_) {
        // HMP 会回显每个按键与光标转义，日志里全是噪声；命令本身已由 _monitor 记录。
      }, onError: (e) => _emit(LogKind.monitor, 'socket error: $e'));
      _emit(LogKind.app, 'monitor 已连接 unix:${_spec!.monitorSock}');
    } catch (e) {
      _emit(LogKind.app, 'monitor 连接失败：$e');
    }
  }

  Future<void> _monitor(String cmd, {bool record = true}) async {
    if (record) _emit(LogKind.monitor, '» $cmd');
    lastCmd.value = cmd;
    try {
      _mon?.write('$cmd\n');
    } catch (e) {
      _emit(LogKind.monitor, 'write failed: $e');
    }
  }

  /// 取帧节流：**按画面是否真的在变**自适应，而不是按时间无条件降速。
  ///
  /// 旧逻辑是「启动 20 s 之后永久降到 900 ms」，于是运行期的页切换动画、指示灯
  /// 闪烁、表盘扫针只剩 ~1 fps，观感就是「动画没渲染」。现在：
  ///   * 画面有变化 → 用 [_fastGrab]（40 ms，与模型侧发布节拍一致）；
  ///   * 连续 [_stillLimit] 帧完全没变 → 降到 [_slowGrab]，省 CPU/磁盘。
  /// 动画一开始变就会立刻回到高速，不需要外部事件。
  void _tickGrab() {
    if (!running.value || _disposed) return;
    // 兜底：动画如果迟迟不结束（模型未加载动画 / 停播日志丢失），12 s 后强制
    // 退出高速采样。计时从**动画开始**算，而不是从上电算——解锁可能发生在上电
    // 15 s 之后，用上电时刻会把刚开始的动画立刻判超时（这是上一版残留的 bug）。
    final animStart = _animStartedAt;
    if (animStart != null &&
        DateTime.now().difference(animStart) > const Duration(seconds: 12)) {
      _animStartedAt = null;
      _animHoldOver = true;
      animating.value = false;
    }
    final interval = _fastGrabPhase ? _fastGrab : _slowGrab;
    final now = DateTime.now();
    if (now.difference(_lastGrab) < interval) return;
    _lastGrab = now;
    _grab();
  }

  /// 画面还在动（或正在播开机动画）就用高频采样。
  bool get _fastGrabPhase {
    if (animating.value) return true;
    // 启动阶段（首帧还没画出来）也要高频，否则会错过首帧时机判断。
    final t = _startedAt;
    if (t != null && !displayLit.value) {
      if (DateTime.now().difference(t) < const Duration(seconds: 20)) return true;
    }
    return _stillGrabs < _stillLimit;
  }

  Future<void> _grab() async {
    if (!running.value || _busy) return;
    _busy = true;
    try {
      final f = File(_spec!.framePath);
      if (!f.existsSync() || f.lengthSync() <= 1024) {
        _frameErrors++;
        return;
      }
      final bytes = await f.readAsBytes();
      final p = parsePpm(bytes);
      if (p == null) {
        _frameErrors++;
        return;
      }
      // 廉价扫描非黑像素占比，驱动"画面是否点亮"的诚实指示：
      // 内核 I2C 快失败后 Launcher 约 4 秒起来、首帧约 6 秒出图，且当前只渲染
      // 原厂信息页（左侧信息栏）——主表盘要等车辆数据，不应误判为故障。
      final rgba = p.rgba;
      final pixels = rgba.length ~/ 4;
      // 画面是否在变：跨步采样算签名（约 512 点，开销可忽略）。
      // 变了 → 立刻回到高频采样（动画/页切换）；连续不变才降速。
      var sig = 2166136261;
      final stepPx = pixels > 512 ? pixels ~/ 512 : 1;
      for (var i = 0; i < pixels; i += stepPx) {
        final o = i * 4;
        sig = ((sig ^ (rgba[o] | (rgba[o + 1] << 8) | (rgba[o + 2] << 16))) *
                16777619) &
            0x7fffffff;
      }
      if (sig == _lastGrabSig) {
        _stillGrabs++;
      } else {
        _stillGrabs = 0;
        _lastGrabSig = sig;
      }
      var nonzero = 0;
      for (var i = 0; i < rgba.length; i += 4) {
        if (rgba[i] > 8 || rgba[i + 1] > 8 || rgba[i + 2] > 8) nonzero++;
      }
      final painted = pixels == 0 ? 0.0 : nonzero / pixels;
      displayPaintedPct.value = painted;
      // 仪表「点亮」= 用户已解锁，或 MCU 三段式进场已完成（固件自己画出了
      // P 档主界面），且画面非黑。上电初期还没点亮时不误判。
      if ((vehicle.state.isAwake || _clusterEntered) &&
          (painted > 0.002 || animating.value)) {
        displayLit.value = true;
      }

      // 仪表启动完成（首帧到达）即转 locked；动画期间不抢跳（动画在 locked 之后
      // 的解锁瞬间才由模型重放，此刻 booting 阶段没有动画在播）。
      if (vehicle.state == VehicleState.booting &&
          painted > 0.002 &&
          (!animating.value || _animHoldOver)) {
        final d = _dispatch(VehicleEvent.bootReady);
        if (d.accepted) {
          status.value = '仪表就绪（待机） · ${vehicle.state.label}';
        }
      }
      final c = Completer<ui.Image>();
      ui.decodeImageFromPixels(
        rgba,
        p.width,
        p.height,
        ui.PixelFormat.rgba8888,
        c.complete,
      );
      final img = await c.future;
      if (_disposed || !running.value) {
        img.dispose();
        return;
      }
      frames.add(img);
      _frameCount++;
    } catch (e) {
      _frameErrors++;
    } finally {
      _busy = false;
    }
  }

  int get frameErrors => _frameErrors;

  /// 已回给 guest 的 CFCP ACK 数（诊断：应为「入站非 ACK 帧数」）。
  int get cfcpAckSent => _cfcpAckSent;

  /// 已收到的完整 CFCP 入站帧数。
  int get cfcpRxFrames => _cfcpRxFrames;

  /// 对端（SoC）通过 CFCP 推来的属性表：prop → 最近一次的值。
  ///
  /// 真车 MCU 也维护这份「仪表认为的车辆状态」，并据此决定要不要回报/纠偏。
  Map<int, int> get peerProps => Map.unmodifiable(_peerProps);

  /// 上电即尝试连上 CFCP（UART1 对端）。
  ///
  /// QEMU 的 chardev 是 `server=on,wait=off`，端口监听可能比本调用晚几百毫秒才就绪，
  /// 所以带退避重试；失败不致命（DashUpFeeder 的每帧发送经 `_cfcpSend` →
  /// `_ensureCfcp` 也会自动补连）。
  void _connectCfcpEarly() {
    var attempt = 0;
    Future<void> tryOnce() async {
      if (!running.value || _disposed) return;
      if (_cfcp != null) return;
      final s = await _ensureCfcp();
      if (s != null) {
        if (_cfcpTrace) _emit(LogKind.mcu, 'CFCP 链路已建立（上电即连）');
        return;
      }
      if (++attempt < 20) {
        Timer(const Duration(milliseconds: 300), tryOnce);
      }
    }

    unawaited(tryOnce());
  }

  /// 确保 CFCP（UART1/ttyS1 对端）socket 已连接。
  Future<Socket?> _ensureCfcp() async {
    final existing = _cfcp;
    if (existing != null) return existing;
    try {
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        _spec!.cfcpPort,
      );
      _cfcp = socket;
      socket.listen(
        _onCfcpData,
        onDone: () {
          if (identical(_cfcp, socket)) _cfcp = null;
        },
        onError: (_) {
          if (identical(_cfcp, socket)) _cfcp = null;
        },
      );
      return socket;
    } catch (e) {
      _emit(LogKind.app, 'CFCP socket 连接失败：$e');
      return null;
    }
  }

  /// guest（内核 CFCP 驱动）→ 客户端方向的字节流。
  ///
  /// 以前这里直接丢弃；但 CFCP 是可靠链路，**只发不收会被对端 3 次重传后丢弃**
  /// （`cfcp_ack_q_work_handl.L131 resend_times is 3`）。所以入站必须解析：
  /// 至少要能识别对端帧并回 ACK，才谈得上「MCU 模拟」。
  void _onCfcpData(List<int> data) {
    if (data.isEmpty) return;
    _cfcpRx.addAll(data);
    if (_cfcpTrace) {
      _emit(LogKind.mcu, 'CFCP ← RX ${data.length}B ${_hex(data)}');
    }
    _drainCfcpRx();
  }

  /// 从缓冲区里切出完整帧（`fe 5a aa a5` … `a5 55 5a`）。
  void _drainCfcpRx() {
    while (true) {
      final start = _indexOfMagic(_cfcpRx);
      if (start < 0) {
        // 没有魔术字：留最后 3 字节防跨界，其余丢弃。
        if (_cfcpRx.length > 3) _cfcpRx.removeRange(0, _cfcpRx.length - 3);
        return;
      }
      if (start > 0) _cfcpRx.removeRange(0, start);
      if (_cfcpRx.length < 14) return; // 头都不全
      // 尾部 3 字节固定 a5 55 5a，从后往前找可避免被负载里的同值误判。
      final end = _findTail(_cfcpRx);
      if (end < 0) {
        if (_cfcpRx.length > 4096) _cfcpRx.clear(); // 防跑飞
        return;
      }
      final frame = _cfcpRx.sublist(0, end + 3);
      _cfcpRx.removeRange(0, end + 3);
      _cfcpRxFrames++;
      _handleCfcpFrame(frame);
    }
  }

  int _indexOfMagic(List<int> b) {
    for (var i = 0; i + 3 < b.length; i++) {
      if (b[i] == 0xfe &&
          b[i + 1] == 0x5a &&
          b[i + 2] == 0xaa &&
          b[i + 3] == 0xa5) {
        return i;
      }
    }
    return -1;
  }

  int _findTail(List<int> b) {
    for (var i = 14; i + 2 < b.length; i++) {
      if (b[i] == 0xa5 && b[i + 1] == 0x55 && b[i + 2] == 0x5a) return i;
    }
    return -1;
  }

  /// 处理一帧完整的对端帧：先回 ACK，再做识别/日志。
  ///
  /// CFCP 是「收到就要应答」的可靠链路：不回 ACK，对端会把同一帧重传 3 次后丢弃
  /// （`cfcp_ack_q_work_handl.L131 resend_times is 3,del list:cmdid:0x75`），
  /// 应用层因此永远拿不到属性。ACK 本身不再回 ACK，否则两端互相 ping-pong。
  void _handleCfcpFrame(List<int> frame) {
    final type = frame.length > 4 ? frame[4] : -1;
    final cmd = frame.length > 6 ? frame[6] : -1;
    if (type != kCfcpTypeAck) {
      _cfcpAckSent++;
      // ACK 不排进 _keyQueue：三段式进场会连续排几十帧数据，若 ACK 排在队尾
      // 会被延迟数秒，guest 内核重传 3 次后就把属性帧丢了
      //（cfcp_ack_q_work_handl ... resend_times is 3）。整帧一次 add，
      // 不会插进别的数据帧中间。
      final socket = _cfcp;
      if (socket != null) {
        socket.add(cfcpAckFrame());
      } else {
        _cfcpSend(cfcpAckFrame());
      }
    }
    // 对端推来的属性帧：记进属性表（SoC 侧广播的仪表状态）。
    final msg = cfcpParseProp(frame);
    if (msg != null) {
      _peerProps[msg.prop] = msg.asInt ?? msg.asU16 ?? 0;
      _applyPeerProp(msg.prop, msg.value);
      if (_cfcpTrace) {
        // 保持 `prop=0x.. sub=.. value=..` 的机读格式（探针/工具链依赖它），
        // 后面再追加人类可读说明。
        _emit(
          LogKind.mcu,
          'CFCP ← prop=0x${msg.prop.toRadixString(16)} '
          'sub=${msg.sub} value=${_peerProps[msg.prop]} '
          '(${describePeerProp(msg.prop, _peerProps[msg.prop]!)})',
        );
      }
    }
    if (!_cfcpTrace) return;
    _emit(
      LogKind.mcu,
      'CFCP ← frame#$_cfcpRxFrames ${frame.length}B '
      'type=0x${type.toRadixString(16)} cmd=0x${cmd.toRadixString(16)} '
      '${_hex(frame)}'
      '${type == kCfcpTypeAck ? ' (ACK)' : ''}',
    );
  }

  /// 把 guest 广播的属性并入 [clusterState] 快照。
  ///
  /// 只收录 `kGuestPublishedProps` 里的属性；其余（setItem/单位/主题等下行命令
  /// 的回执）保留在 [peerProps] 里按需查。
  void _applyPeerProp(int prop, List<int> value) {
    if (!kGuestPublishedProps.contains(prop)) return;
    final s = clusterState.value;
    final now = DateTime.now();
    switch (prop) {
      case CfcpProp.lampMask:
        clusterState.value = s.copyWith(lampMask: _asInt(value), updatedAt: now);
        break;
      case CfcpProp.gear:
        clusterState.value = s.copyWith(gear: _asInt(value), updatedAt: now);
        break;
      case CfcpProp.status:
        clusterState.value = s.copyWith(status: _asInt(value), updatedAt: now);
        break;
      case CfcpProp.handshake:
        clusterState.value = s.copyWith(handshake: _asInt(value), updatedAt: now);
        break;
      case CfcpProp.swVersion:
        clusterState.value = s.copyWith(
          swVersion: String.fromCharCodes(value.takeWhile((b) => b != 0)),
          updatedAt: now,
        );
        break;
      case CfcpProp.heartbeat:
        clusterState.value = s.copyWith(
          heartbeatCount: s.heartbeatCount + 1,
          updatedAt: now,
        );
        break;
      case CfcpProp.tireTemp:
        clusterState.value = s.copyWith(tireTemp: _asInt(value), updatedAt: now);
        break;
      case CfcpProp.tireLost:
        clusterState.value = s.copyWith(tireLost: _asInt(value), updatedAt: now);
        break;
    }
  }

  /// 属性值字节 → int（小端，1~4 字节；更长则取前 4 字节）。
  int _asInt(List<int> value) {
    var v = 0;
    final n = value.length > 4 ? 4 : value.length;
    for (var i = 0; i < n; i++) {
      v |= value[i] << (8 * i);
    }
    return v;
  }

  String _hex(List<int> b) =>
      b.map((v) => v.toRadixString(16).padLeft(2, '0')).join(' ');

  /// 把一帧 CFCP 字节写进 ttyS1（UART1 对端）。串行化，避免多帧交错。
  Future<void> _cfcpSend(List<int> frame, {String? log}) {
    if (!running.value) return Future.value();
    _keyQueue = _keyQueue.then((_) async {
      final socket = await _ensureCfcp();
      if (socket == null) return;
      try {
        socket.add(frame);
        await socket.flush();
        if (log != null) _emit(LogKind.mcu, log);
      } catch (e) {
        _cfcp?.destroy();
        _cfcp = null;
        _emit(LogKind.app, 'CFCP 发送失败：$e');
      }
    });
    return _keyQueue;
  }

  /// 上电即启动 MCU 对端（真车 MCU 与仪表同电源上电，不等用户解锁）。
  ///
  /// 2026-11-05 修复：旧实现只在「用户解锁」后发 11-02 的基线帧
  ///（版本/握手/能力/状态/旧档位/心跳），既没有 KL15=0x99，也没有
  /// synchronization_status 解锁闸门和 vehicle_info2 挡位，所以固件一直
  /// 停在黑屏 / 4.37% 非黑的待机统计页 —— 蓝绿背景、右侧大 P、整车和
  /// 进场动画全都出不来。
  ///
  /// 现在统一由 [DashUpFeeder] 按 EMULATION.md §41 的三段式进场喂数据：
  /// pre-arm（KL15+RTC，禁喂解锁）→ settle（20 拍 gear=0）→
  /// enter（只写一次 gear=1）→ 0.5 s 保持心跳 + 掉回待机时自愈。
  /// 所有画面元素都由 guest 里原厂 DashTheme01 自己绘制，这里不合成像素。
  void _startDashUp() {
    _stopDashUp();
    final feeder = DashUpFeeder(
      send: (f) => _cfcpSend(f),
      paintedPct: () => displayPaintedPct.value,
      animating: () => animating.value,
      telemetry: telemetry,
      onLog: (s) => _emit(LogKind.mcu, s),
      onPhase: (p, _) {
        switch (p) {
          case DashUpPhase.enter:
            status.value = '仪表点亮中 · P 档进场动画';
            break;
          case DashUpPhase.hold:
            _clusterEntered = true;
            status.value = 'P 档主界面 · 固件原生渲染';
            break;
          case DashUpPhase.healing:
            status.value = '仪表重启 · 重放进场序列';
            break;
          default:
            break;
        }
      },
    );
    _dashUp = feeder;
    unawaited(feeder.start());
  }

  void _stopDashUp() {
    _dashUp?.stop();
    _dashUp = null;
    _clusterEntered = false;
  }

  /// 车身语义状态变化时的处理。
  ///
  /// 发下行灯态位图（0x21407072，集群不消费，实测 0 px）；真正驱动顶部
  /// 指示灯的是上行 indicator_lamp 0x2170951E（EMULATION.md §41）。
  /// 该属性默认**不喂**：固件从不擦除旧像素，灯只能加不能减，且 ABS_fault
  /// 会弹故障框卡住 App；要喂必须在进场动画之后只喂一次。
  void _emitMcuState() {
    if (!running.value) return;
    for (final f in gd32StateFrames(mcu.state.value)) {
      _cfcpSend(f, log: 'MCU → ${describeFrame(f)}');
    }
    _emit(
      LogKind.mcu,
      'MCU 车身状态：${mcu.state.value.summary} '
      '（灯态位图=0x${lampMaskFromState(mcu.state.value).toRadixString(16)}）',
    );
  }

  /// 直接把一条**原始 CFCP 帧**写进 ttyS1。
  ///
  /// 给协议实验/取证探针用（例如扫上行帧变体）。正常业务路径不要走这里：
  /// 属性帧用 [sendVehicleProp]、按键用 [pressInstrumentKey]。
  Future<void> sendRawFrame(List<int> frame, {String? log}) =>
      _cfcpSend(frame, log: log ?? 'RAW → ${_hex(frame)}');

  /// 直接向 ttyS1 发一条 MCU 属性上报帧。
  ///
  /// 正式路径是 `McuSim` → `_emitMcuState()`；这个入口留给**属性 id 校准**：
  /// 真机固件里 prop id → 仪表控件的映射尚未逐项确认，需要用候选 id 逐条打进去、
  /// 再比对 framebuffer 才能定论（见 EMULATION.md §27）。
  Future<void> sendVehicleProp(
    int propId, {
    int? intValue,
    List<int>? rawValue,
    int sub = 0,
    bool log = true,
  }) {
    final f = cfcpPropFrame(
      propId,
      sub,
      intValue: intValue,
      rawValue: rawValue,
    );
    return _cfcpSend(f, log: log ? 'GD32 → ${describeFrame(f)}' : null);
  }

  Future<void> sendKeyEvent(String label, int? keyId, bool pressed) {
    if (!running.value) {
      _emit(LogKind.app, '按键「$label」未发送：QEMU 尚未运行');
      return Future.value();
    }
    if (keyId == null) {
      _emit(LogKind.app, '按键「$label」尚未映射到原厂协议，未注入');
      return Future.value();
    }
    return _cfcpSend(
      cfcpKeyFrame(keyId, pressed),
      log:
          '按键「$label」→ CFCP 0x${keyId.toRadixString(16)} '
          '${pressed ? "按下" : "释放"}',
    );
  }

  /// 兼容旧调用：语义等同真车「整车下电」，走正常关机而不是杀进程。
  Future<VehicleDecision> requestPowerOff(String source) async {
    final d = _dispatch(VehicleEvent.shutdownRequest);
    if (!d.accepted) {
      _emit(LogKind.app, '$source：${d.hint}');
      return d;
    }
    _emit(LogKind.app, '$source：正常下电流程（先仪表关机，再拔电）');
    await _gracefulShutdown();
    return d;
  }

  /// 请求 guest 正常关机：发送 sync + poweroff，等它自己报 Power down。
  Future<void> _gracefulShutdown() async {
    if (!running.value || _shutdownRequested) return;
    _shutdownRequested = true;
    status.value = '下电中 · 等待 guest 关机';
    _emit(
      LogKind.app,
      '通过 guest 串口执行 Linux 正常关机，不立即杀 QEMU；收到 Power down 后才结束会话',
    );
    _shutdownTimer = Timer(const Duration(seconds: 25), () {
      if (!_disposed && running.value && _shutdownRequested) {
        status.value = '下电未完成 · 可强制拔电';
        _emit(LogKind.app, '25 秒内未收到 guest 关机确认；保留进程与日志，请强制拔电或继续等待');
      }
    });
    _proc?.stdin.write('\n');
    _sendShutdownCommand();
  }

  /// 正常下电完成后的「拔电」收尾。
  Future<void> _finalizeUnplug() async {
    _forceStopping = true;
    status.value = '已断电';
    _emit(LogKind.mcu, 'MCU: power-down — cluster held dark');
    // 断电后转向/双闪/远光/定速全灭。
    mcu.resetOnPowerOff();
    _shutdownTimer?.cancel();
    try {
      _mon?.destroy();
    } catch (_) {}
    _mon = null;
    _cfcp?.destroy();
    _cfcp = null;
    _proc?.kill();
    await bridge.stop();
    _cleanup();
  }

  void _sendShutdownCommand() {
    if (!_consoleReady || !_shutdownRequested || _shutdownCommandSent) return;
    _shutdownCommandSent = true;
    // 先触发关机动画（模型倒放 logo），给约 2 秒播放，再真正关机，
    // 让面板在变黑前能播完 logo-out。
    if (_shutdownWakeFile != null && !_shutdownAnimSent) {
      _shutdownAnimSent = true;
      try {
        File(_shutdownWakeFile!).writeAsStringSync('shutdown\n');
        _emit(LogKind.mcu, 'MCU: 触发关机动画（logo out）');
      } catch (_) {}
      Future.delayed(const Duration(milliseconds: 2200), () {
        if (_disposed) return;
        _reallyPoweroff();
      });
      return;
    }
    _reallyPoweroff();
  }

  void _reallyPoweroff() {
    _emit(
      LogKind.app,
      '已向 guest console 发送 sync; /sbin/poweroff -f（Linux 内核关机回退，绕过不响应 busybox 信号的 vendor init）',
    );
    _proc?.stdin.write('\n(sync; /sbin/poweroff -f)\n');
  }

  Future<void> systemReset() async {
    await _monitor('system_reset');
  }

  /// 低层收尾：强制结束 QEMU。UI 的「拔电」走 [unplugPower]/[confirmUnsafeCut]，
  /// 这里只用于窗口关闭或测试清理；若整车仍在通电，按异常下电记录。
  Future<void> stop() async {
    _forceStopping = true;
    _starting = false;
    if (vehicle.state.isPowered) {
      _dispatch(VehicleEvent.forceCut);
    } else if (vehicle.state == VehicleState.poweredOff ||
        vehicle.state == VehicleState.unsafeCut) {
      _dispatch(VehicleEvent.unplug);
    }
    status.value = vehicle.state.label;
    _emit(LogKind.app, '结束 QEMU 进程');
    try {
      _mon?.destroy();
    } catch (_) {}
    _mon = null;
    _cfcp?.destroy();
    _cfcp = null;
    _proc?.kill();
    await bridge.stop();
    await Future.delayed(const Duration(milliseconds: 300));
    _cleanup();
  }

  void _cleanup() {
    _shutdownTimer?.cancel();
    _shutdownRequested = false;
    _shutdownCommandSent = false;
    _mcuTimer?.cancel();
    _stopDashUp();
    _wakeFile = null;
    _wakeFired = false;
    _shutdownWakeFile = null;
    _shutdownAnimSent = false;
    // 注意：不重置整车状态。正常关机后应停在 poweredOff，等用户「拔电」；
    // 异常退出则停在 unsafeCut，保留告警。
    _timer?.cancel();
    _tick?.cancel();
    _timer = null;
    _tick = null;
    _proc = null;
    _mon?.destroy();
    _mon = null;
    _cfcp?.destroy();
    _cfcp = null;
    running.value = false;
    pid.value = null;
    _startedAt = null;
    _animHoldOver = true;
    _animStartedAt = null;
    animating.value = false;
  }

  void dispose() {
    _shutdownTimer?.cancel();
    _disposed = true;
    _starting = false;
    _stopDashUp();
    bridge.stop();
    _timer?.cancel();
    _tick?.cancel();
    _proc?.kill();
    _mon?.destroy();
    _cfcp?.destroy();
    clusterState.dispose();
    mcu.dispose();
  }
}
