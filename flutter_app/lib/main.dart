// ZEEHO AE5i 仪表模拟器 —— Flutter 前端。
//
// 结构（详见 docs/BACKEND-DESIGN.md「仿真客户端结构」）：
//   lib/emu/paths.dart     自建 QEMU / SPVD / 原始 dump 的路径解析（**不回落系统 QEMU**）
//   lib/emu/spvd.dart      SPVD 虚拟硬盘读取器（头 / 坏块表 / 分区表 / 抽内核）
//   lib/emu/machine.dart   机器模型 sunplus-sp8368 的启动规格与命令行构造
//   lib/emu/controller.dart  QEMU 子进程、串口桥、monitor、抓帧
//   lib/emu/keys.dart      实车 13 个把手控件
//   lib/emu/ppm.dart       framebuffer PPM 解码
//
// 前端不用 HTTP：它直接持有 QEMU 子进程，串口走 stdout、画面走 framebuffer 快照。

import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:flutter/material.dart';

import 'emu/controller.dart';
import 'emu/gd32.dart';
import 'emu/keys.dart';
import 'emu/machine.dart';
import 'emu/mcu.dart';
import 'emu/password.dart';
import 'emu/paths.dart';
import 'emu/spvd.dart';
import 'emu/vehicle.dart';

export 'emu/controller.dart';
export 'emu/keys.dart';
export 'emu/machine.dart';
export 'emu/paths.dart';
export 'emu/ppm.dart';
export 'emu/spvd.dart';
export 'emu/vehicle.dart';

void main() => runApp(const EmuApp());

class EmuApp extends StatelessWidget {
  const EmuApp({super.key});

  @override
  Widget build(BuildContext context) {
    final dark = ThemeData.dark(useMaterial3: true);
    return MaterialApp(
      title: 'ZEEHO AE5i 仪表模拟器',
      debugShowCheckedModeBanner: false,
      theme: dark.copyWith(
        scaffoldBackgroundColor: const Color(0xFF111417),
        colorScheme: dark.colorScheme.copyWith(
          surface: const Color(0xFF181C20),
          primary: const Color(0xFF3DDC97),
        ),
      ),
      home: const EmuPage(),
    );
  }
}

class EmuPage extends StatefulWidget {
  final bool autoStart;
  const EmuPage({super.key, this.autoStart = false});

  @override
  State<EmuPage> createState() => _EmuPageState();
}

class _EmuPageState extends State<EmuPage> with SingleTickerProviderStateMixin {
  final c = QemuController();
  final logLines = <LogLine>[];
  final logScroll = ScrollController();
  ui.Image? frame;
  bool autoscroll = true;
  String? pressedKey;
  String? selectedSpvd;
  String bootStage = '待机';
  String? bootError;
  late final AnimationController _bootAnimation;
  bool starting = false;
  final enabledLogs = LogKind.values.toSet();

  @override
  void initState() {
    super.initState();
    selectedSpvd = LabPaths.resolveSpvd();
    if (selectedSpvd != null) {
      c.vdisk.value = SpvdImage.open(selectedSpvd!);
    }
    _bootAnimation = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    );
    c.log.stream.listen((l) {
      if (!mounted) return;
      setState(() {
        final last = logLines.isEmpty ? null : logLines.last;
        if (last != null &&
            last.kind == l.kind &&
            last.text == l.text &&
            l.text.length < 200) {
          last.count++;
        } else {
          logLines.add(l);
        }
        if (logLines.length > 4000) logLines.removeRange(0, 1000);
      });
      if (autoscroll) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (logScroll.hasClients) {
            logScroll.jumpTo(logScroll.position.maxScrollExtent);
          }
        });
      }
    });
    c.frames.stream.listen((img) {
      if (!mounted) {
        img.dispose();
        return;
      }
      final previous = frame;
      setState(() => frame = img);
      if (previous != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) => previous.dispose());
      }
    });
    c.status.addListener(_syncStatus);
    c.pid.addListener(_trackQemu);
    if (widget.autoStart) _startSequence();
  }

  void _syncStatus() {
    if (mounted) {
      setState(() {
        bootStage = c.status.value;
        bootError = c.lastError.value;
      });
    }
  }

  Future<void> _trackQemu() async {
    try {
      await const MethodChannel(
        'ae5i/files',
      ).invokeMethod<void>('trackQemu', c.pid.value);
    } catch (_) {
      // Native channel is absent in headless widget tests.
    }
  }

  @override
  void dispose() {
    c.status.removeListener(_syncStatus);
    c.pid.removeListener(_trackQemu);
    c.dispose();
    _bootAnimation.dispose();
    frame?.dispose();
    logScroll.dispose();
    super.dispose();
  }

  Future<void> _startSequence() async {
    if (c.running.value || starting) return;
    setState(() {
      starting = true;
      bootError = null;
      bootStage = '正在上电';
      final oldFrame = frame;
      frame = null;
      if (oldFrame != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) => oldFrame.dispose());
      }
    });
    try {
      final d = await c.powerOn(spvdPath: selectedSpvd);
      if (mounted && !d.accepted) _toast(d.hint);
    } finally {
      if (mounted) {
        setState(() {
          starting = false;
          bootError = c.lastError.value;
          bootStage = c.status.value;
        });
      }
    }
  }

  void _appLog(String text) => c.log.add(LogLine(LogKind.app, text));

  Future<void> _chooseFirmware() async {
    final controller = TextEditingController(text: selectedSpvd ?? '');
    final path = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('选择仪表固件'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'SPVD 文件路径',
            hintText: '/path/to/ae5i-software.spvd',
          ),
          onSubmitted: (v) => Navigator.pop(context, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('加载'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (!mounted || path == null || path.isEmpty) return;
    final image = SpvdImage.open(path);
    setState(() {
      selectedSpvd = image == null ? path : image.path;
      bootStage = image == null ? '固件无效' : '已加载固件';
      bootError = image == null ? '无法读取 SPVD 文件' : null;
      c.vdisk.value = image;
    });
    _appLog(image == null ? '固件加载失败：$path' : '固件加载成功：$path');
  }

  Future<void> _exportLogs() async {
    final text = [
      'AE5I emulator log — ${DateTime.now().toIso8601String()}',
      '状态: ${c.status.value}',
      '错误: ${c.lastError.value ?? "无"}',
      'SPVD: ${selectedSpvd ?? c.vdisk.value?.path ?? "未选择"}',
      '命令: ${c.spec?.shellLine() ?? "尚未启动"}',
      for (final l in logLines)
        '${l.t.toIso8601String()} [${l.kind.name}] ${l.text}${l.count > 1 ? " x${l.count}" : ""}',
    ].join('\n');
    try {
      final path = await const MethodChannel('ae5i/files').invokeMethod<String>(
        'saveLog',
        {
          'text': text,
          'name': 'ae5i-emulator-${DateTime.now().millisecondsSinceEpoch}.log',
        },
      );
      if (!mounted || path == null) return;
      _appLog('日志已导出：$path');
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('日志已导出：$path')));
    } catch (e) {
      if (!mounted) return;
      _appLog('日志导出失败：$e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('日志导出失败：$e'),
          action: SnackBarAction(
            label: '复制日志',
            onPressed: () => Clipboard.setData(ClipboardData(text: text)),
          ),
        ),
      );
    }
  }

  Color _color(LogKind k) => switch (k) {
    LogKind.qemu => const Color(0xFF7FB2FF),
    LogKind.serial => const Color(0xFFCBD5DF),
    LogKind.monitor => const Color(0xFFC08CFF),
    LogKind.app => const Color(0xFF3DDC97),
    LogKind.mcu => const Color(0xFF6FD3E0),
  };

  bool _alarm(String s) => RegExp(
    r'panic|fault|error|failed|ERR|Cannot|cannot find|segv|refused',
    caseSensitive: false,
  ).hasMatch(s);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          _header(),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  flex: 5,
                  child: Column(
                    children: [
                      Expanded(child: _screenPanel()),
                      _vehicleControls(),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(flex: 4, child: _rightPanel()),
              ],
            ),
          ),
          _keyBar(),
        ],
      ),
    );
  }

  Widget _header() {
    return Container(
      height: 46,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: const BoxDecoration(
        color: Color(0xFF181C20),
        border: Border(bottom: BorderSide(color: Color(0xFF2A3038))),
      ),
      child: Row(
        children: [
          ValueListenableBuilder<bool>(
            valueListenable: c.running,
            builder: (_, v, _) => Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: v ? const Color(0xFF3DDC97) : const Color(0xFF66707A),
                boxShadow: v
                    ? [const BoxShadow(color: Color(0x883DDC97), blurRadius: 8)]
                    : null,
              ),
            ),
          ),
          const SizedBox(width: 10),
          const Text(
            'ZEEHO AE5i 仪表模拟器',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              bootStage,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 10, color: Color(0xFF8A96A3)),
            ),
          ),
          const SizedBox(width: 10),
          ValueListenableBuilder<VehicleState>(
            valueListenable: c.vehicleState,
            builder: (_, s, _) => _stateBadge(s),
          ),
          const SizedBox(width: 10),
          IconButton(
            tooltip: '选择固件',
            iconSize: 17,
            onPressed: c.running.value || starting ? null : _chooseFirmware,
            icon: const Icon(Icons.folder_open),
          ),
          ValueListenableBuilder<Duration>(
            valueListenable: c.uptime,
            builder: (_, d, _) => Text(
              '${d.inMinutes.toString().padLeft(2, '0')}:${(d.inSeconds % 60).toString().padLeft(2, '0')}',
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                color: Color(0xFF8A96A3),
              ),
            ),
          ),
          const SizedBox(width: 14),
          ValueListenableBuilder<bool>(
            valueListenable: c.running,
            builder: (_, v, _) => Row(
              children: [
                FilledButton.tonal(
                  onPressed: v || starting ? null : _startSequence,
                  child: const Text('12V 上电'),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: v ? () => c.requestPowerOff('客户端停止') : null,
                  child: const Text('仪表关机 / 锁定'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------- 整车启动 / 关机流程

  Color _stateColor(VehicleState s) => switch (s) {
    VehicleState.off => const Color(0xFF66707A),
    VehicleState.booting => const Color(0xFF7FB2FF),
    VehicleState.locked => const Color(0xFFFFB454),
    VehicleState.unlocked => const Color(0xFF3DDC97),
    VehicleState.ready => const Color(0xFF6CF0B0),
    VehicleState.poweringOff => const Color(0xFF7FB2FF),
    VehicleState.poweredOff => const Color(0xFF8A96A3),
    VehicleState.unsafeCut => const Color(0xFFFF7B72),
  };

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(seconds: 3)),
    );
  }

  Future<void> _runVehicle(Future<VehicleDecision> Function() action) async {
    if (starting) return;
    setState(() => starting = true);
    try {
      final d = await action();
      if (!mounted) return;
      if (!d.accepted &&
          d.effect != VehicleEffect.promptPassword &&
          d.effect != VehicleEffect.confirmUnsafeCut) {
        _toast(d.hint);
      }
    } finally {
      if (mounted) setState(() => starting = false);
    }
  }

  /// 长按 Ready：蓝牙已连 TBOX 直接解锁；无连接则请求仪表显示固件原生
  /// `PasswordUL` 密码界面。客户端不画任何密码界面，也不弹密码框。
  Future<void> _readyLongPress() async {
    if (starting) return;
    setState(() => starting = true);
    try {
      final d = await c.longPressReady(spvdPath: selectedSpvd);
      if (!mounted) return;
      // promptPassword = 已请求固件原生密码界面，画面区直接显示 framebuffer，
      // 不需要也不允许任何客户端提示覆盖它。
      if (!d.accepted &&
          d.effect != VehicleEffect.promptPassword &&
          d.effect != VehicleEffect.confirmUnsafeCut) {
        _toast(d.hint);
      }
    } finally {
      if (mounted) setState(() => starting = false);
    }
  }

  Future<void> _unplug() async {
    if (starting) return;
    setState(() => starting = true);
    try {
      final d = await c.unplugPower();
      if (!mounted) return;
      if (d.effect == VehicleEffect.confirmUnsafeCut) {
        final confirmed = await _confirmUnsafeCut(d.state);
        if (confirmed == true) {
          final cut = await c.confirmUnsafeCut();
          if (mounted) _toast(cut.hint);
        } else if (mounted) {
          _toast('已取消拔电：请先刷卡关机或长按 Ready 关机');
        }
        return;
      }
      if (!d.accepted) _toast(d.hint);
    } finally {
      if (mounted) setState(() => starting = false);
    }
  }

  Future<bool?> _confirmUnsafeCut(VehicleState state) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(
          Icons.warning_amber_rounded,
          color: Color(0xFFFFB454),
          size: 30,
        ),
        title: const Text('直接拔电 = 异常下电'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('当前整车仍在「${state.label}」，没有走正常关机流程。'),
            const SizedBox(height: 8),
            const Text(
              '真车正确下电顺序：先刷卡关机，或长按 Ready 关机；等仪表断电后，再拔出电源。'
              '直接拔电可能对车辆电力系统造成影响。',
            ),
            const SizedBox(height: 8),
            const Text(
              '仿真中继续只会在日志里标记「异常下电」，不会损坏任何真实设备。',
              style: TextStyle(fontSize: 11, color: Color(0xFF8A96A3)),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消，先关机'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF8B3A34),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认强制拔电'),
          ),
        ],
      ),
    );
  }

  Widget _stateBadge(VehicleState s) {
    final color = _stateColor(s);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.55)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(shape: BoxShape.circle, color: color),
          ),
          const SizedBox(width: 6),
          Text(
            s.label,
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  /// 主流程条：断电 › 上电 › 未解锁 › 已解锁 › READY › 关机 › 拔电
  Widget _flowStrip(VehicleState state) {
    const labels = ['12V 断电', '通电待机', '仪表启动/密码', '解锁 P', '前进 READY', '关机锁定', '异常断电'];
    final active = state.flowIndex;
    final spans = <TextSpan>[];
    for (var i = 0; i < labels.length; i++) {
      if (i > 0) {
        spans.add(
          const TextSpan(
            text: ' › ',
            style: TextStyle(fontSize: 10, color: Color(0xFF4A5560)),
          ),
        );
      }
      final on = i == active;
      spans.add(
        TextSpan(
          text: labels[i],
          style: TextStyle(
            fontSize: 10,
            fontWeight: on ? FontWeight.w700 : FontWeight.w400,
            color: on
                ? _stateColor(state)
                : (i < active
                      ? const Color(0xFF8A96A3)
                      : const Color(0xFF5A6570)),
          ),
        ),
      );
    }
    return RichText(
      text: TextSpan(children: spans),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }

  Widget _action(String label, bool enabled, VoidCallback onPressed) {
    return FilledButton.tonal(
      onPressed: enabled ? onPressed : null,
      style: FilledButton.styleFrom(
        visualDensity: VisualDensity.compact,
        minimumSize: const Size(0, 30),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        textStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
      ),
      child: Text(label),
    );
  }

  Widget _connChip(
    String label,
    ValueListenable<bool> value,
    ValueChanged<bool> onChanged,
  ) {
    return ValueListenableBuilder<bool>(
      valueListenable: value,
      builder: (_, on, _) => FilterChip(
        label: Text(label, style: const TextStyle(fontSize: 10)),
        selected: on,
        onSelected: onChanged,
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: const EdgeInsets.symmetric(horizontal: 2),
      ),
    );
  }

  Widget _vehicleControls() {
    return ListenableBuilder(
      listenable: Listenable.merge([
        c.vehicleState,
        c.bleConnected,
        c.tboxOnline,
      ]),
      builder: (_, _) {
        final state = c.vehicleState.value;
        final canUnlock =
            state == VehicleState.poweredOff ||
            state == VehicleState.booting ||
            state == VehicleState.locked;
        return Container(
          margin: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
          decoration: BoxDecoration(
            color: const Color(0xFF181C20),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFF252B32)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _stateBadge(state),
                  const SizedBox(width: 10),
                  Expanded(child: _flowStrip(state)),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  _action(
                    '12V 上电',
                    !starting &&
                        (state == VehicleState.off ||
                            state == VehicleState.unsafeCut),
                    () => _runVehicle(() => c.powerOn(spvdPath: selectedSpvd)),
                  ),
                  _action(
                    '刷 NFC 卡',
                    !starting && state.isPowered,
                    () =>
                        _runVehicle(() => c.swipeCard(spvdPath: selectedSpvd)),
                  ),
                  _action(
                    'App 解锁',
                    !starting && c.tboxOnline.value && canUnlock,
                    () =>
                        _runVehicle(() => c.appUnlock(spvdPath: selectedSpvd)),
                  ),
                  _action(
                    'Ready 长按',
                    !starting &&
                        (state == VehicleState.poweredOff ||
                            state == VehicleState.locked ||
                            state == VehicleState.unlocked ||
                            state == VehicleState.ready),
                    _readyLongPress,
                  ),
                  _action('12V 下电', !starting, _unplug),
                  _connChip('TBOX 蓝牙钥匙 cfmoto-xxxx', c.bleConnected, c.setBleConnected),
                  _connChip('TBOX 在线', c.tboxOnline, c.setTboxOnline),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                '下一步：${state.nextStep}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 10,
                  height: 1.35,
                  color: Color(0xFF7E8894),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _screenPanel() {
    // 面板真实尺寸来自设备自身：runtime_cfg 的 UI_width/UI_height 是 1024×600
    // （≈16:9），anm_logo 的 logo.mkv 和主题整屏资源也是 1024×600。以前这里写死
    // 800×480，画面被横向压扁，底部状态栏因此看起来像"缺了一块"。
    // 有真实帧时直接用帧的比例，没有时用面板比例兜底。
    final aspect = (frame != null && frame!.height > 0)
        ? frame!.width / frame!.height
        : 1024 / 600;
    return _panel(
      title: '仪表画面 · 1024×600',
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Center(
          child: AspectRatio(
            aspectRatio: aspect,
            child: Container(
              decoration: BoxDecoration(
                color: Colors.black,
                border: Border.all(color: const Color(0xFF000000)),
                borderRadius: BorderRadius.circular(4),
              ),
              clipBehavior: Clip.antiAlias,
              child: ListenableBuilder(
                listenable: Listenable.merge([c.vehicleState, c.pwNotifier, c.authTransitionBlank]),
                builder: (_, _) {
                  if (c.authTransitionBlank.value) {
                    return const ColoredBox(color: Colors.black);
                  }
                  final state = c.vehicleState.value;
                  final passwordUi = c.vehicle.passwordMode;
                  // ★ 密码会话期间画面区**只显示 framebuffer**：固件原生
                  //   PasswordUL 由 guest 自己绘制。客户端不叠徽标、不画密码盘、
                  //   不弹提示横幅，也不让待机占位盖住仪表画面。
                  final awake = state.isAwake || passwordUi;
                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      // 真车：仪表只在「解锁（车辆启动）」后才点亮。上电→MCU 启动→
                      // 等待解锁这段保持黑屏待机；但进入原生密码界面必须直显
                      // framebuffer，否则固件自己画的界面会被占位遮住。
                      if (awake)
                        (frame == null || !c.running.value
                            ? _bootSplash()
                            : RawImage(image: frame, fit: BoxFit.contain))
                      else
                        _clusterStandby(state),
                      // 客户端仿真层 HUD（密码会话期间完全隐藏，不抢固件画面）
                      if (!passwordUi)
                        Positioned(left: 8, top: 8, child: _stateBadge(state)),
                      // 画面点亮后的诚实提示横幅（黑屏期 / 局部页面都在预期内）。
                      if (!passwordUi && awake)
                        ListenableBuilder(
                          listenable: Listenable.merge([
                            c.displayLit,
                            c.displayPaintedPct,
                            c.animating,
                            c.shutdownAnimating,
                          ]),
                          builder: (_, _) {
                            // 下电时面板仍在亮着：先播原厂 logo-out，别用
                            // 「开机动画」文案，也别让待机占位盖住画面。
                            if (c.shutdownAnimating.value) {
                              return _displayHint(
                                '关机动画 · 原厂 logo out',
                                '模型倒放 anm_logo 的 112 帧；播完后 guest '
                                    'poweroff 才把面板变黑',
                                accent: true,
                              );
                            }
                            if (c.animating.value) {
                              return _displayHint(
                                '开机动画 · 原厂 logo',
                                '解锁后仪表点亮，这段动画由设备自己的 anm_logo 分区解码重放，'
                                    '播完后由 Launcher 接管画面',
                                accent: true,
                              );
                            }
                            if (!c.displayLit.value) {
                              return _displayHint(
                                '仪表点亮中',
                                '内核与 Launcher 正在启动，期间黑屏属正常现象',
                                accent: false,
                              );
                            }
                            if (c.displayPaintedPct.value < 0.08) {
                              return _displayHint(
                                '已点亮 · 原厂信息页',
                                'CFCP 对端已接通；车辆数据到主表盘的映射及 PFC 背景合成尚未闭环',
                                accent: true,
                              );
                            }
                            return const SizedBox.shrink();
                          },
                        ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
      footer: const Padding(
        padding: EdgeInsets.fromLTRB(12, 0, 12, 8),
        child: Text(
          '画面来自原厂 framebuffer；CFCP 链路已接通，车辆数据映射与 PFC 背景层仍待闭环。',
          style: TextStyle(
            fontSize: 10.5,
            color: Color(0xFF7E8894),
            height: 1.45,
          ),
        ),
      ),
    );
  }

  /// 仪表画面点亮状态的诚实提示横幅（顶部居中，不与画面内容争抢视线）。
  /// [accent]=false 表示「黑屏期」（蓝，正常启动中）；=true 表示「已点亮但局部页面」（黄）。
  Widget _displayHint(String title, String sub, {required bool accent}) {
    final color = accent ? const Color(0xFFFFB454) : const Color(0xFF4A90D9);
    return Positioned(
      top: 8,
      left: 8,
      right: 8,
      child: Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 360),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: const Color(0xCC101417),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: color.withValues(alpha: 0.4)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                sub,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 9.5, color: Color(0xFFB8C0C6)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // 密码解锁没有客户端界面：4 位输入由固件 `PasswordUL` 自己绘制，
  // 校验与会话状态在 MCU 仿真器（emu/password.dart），画面区只直显 framebuffer。

  /// 仪表待机（黑屏）占位：对应真车「上电 → MCU 启动 → 等待解锁」整段，
  /// 仪表保持断电黑屏，只有解锁（车辆启动）后才点亮。
  Widget _clusterStandby(VehicleState state) {
    final booting = state == VehicleState.booting;
    return Container(
      color: Colors.black,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              booting ? Icons.memory : Icons.lock_outline,
              size: 38,
              color: const Color(0xFF3DDC97).withValues(alpha: 0.85),
            ),
            const SizedBox(height: 14),
            Text(
              booting ? '仪表待机 · MCU 启动中' : '仪表待机 · 等待解锁',
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w500,
                color: Color(0xFFE9EEF2),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              booting
                  ? 'MCU 已上电，串口正输出启动日志；仪表保持黑屏待机'
                  : '刷卡 / 蓝牙连 TBOX 后长按 Ready / App 解锁\n'
                        '解锁后仪表才点亮',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 11,
                height: 1.5,
                color: Color(0xFF8A96A3),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _bootSplash() {
    return AnimatedBuilder(
      animation: _bootAnimation,
      builder: (_, _) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              '等待固件画面',
              style: TextStyle(
                letterSpacing: 5,
                fontSize: 18,
                fontWeight: FontWeight.w300,
                color: Color(0xFFE9EEF2),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              bootStage,
              style: const TextStyle(color: Color(0xFF8A96A3), fontSize: 11),
            ),
            const SizedBox(height: 14),
            SizedBox(
              width: 170,
              child: LinearProgressIndicator(
                value: starting || c.running.value ? null : 0,
              ),
            ),
            if (bootError != null) ...[
              const SizedBox(height: 12),
              Text(
                bootError!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Color(0xFFFF7B72), fontSize: 10),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _rightPanel() {
    return Column(
      children: [
        _vdiskPanel(),
        const SizedBox(height: 8),
        _qemuPanel(),
        const SizedBox(height: 8),
        Expanded(child: _logPanel()),
      ],
    );
  }

  // ------------------------------------------------------------ vdisk panel

  Widget _vdiskPanel() {
    return _panel(
      title: '虚拟硬盘 · SPVD（NAND → 线性窗口）',
      expand: false,
      actions: [
        IconButton(
          tooltip: '重新扫描',
          iconSize: 15,
          onPressed: () async {
            final p = LabPaths.resolveSpvd();
            c.vdisk.value = p == null ? null : SpvdImage.open(p);
            setState(() {});
          },
          icon: const Icon(Icons.refresh),
        ),
      ],
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
        child: ValueListenableBuilder<SpvdImage?>(
          valueListenable: c.vdisk,
          builder: (_, img, _) {
            if (img == null) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _kv('状态', '未加载'),
                  _kv('生成', LabPaths.spvdHint),
                  const Text(
                    'SPVD = 0x1000 自描述头（几何 / 坏块 / 分区 + CRC32）+ 去 OOB 的扁平页数据，'
                    '由 sunplus-vdisk 同时给出「线性数据窗」和「分区寄存器窗」。',
                    style: TextStyle(
                      fontSize: 10,
                      color: Color(0xFF7E8894),
                      height: 1.45,
                    ),
                  ),
                ],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _kv('文件', img.path),
                _kv('几何', '${img.geometryText} · ${img.sizeText}'),
                _kv(
                  '坏块',
                  '${img.badBlocks.length} 个 ${img.badBlocks.isEmpty ? '' : img.badBlocks.toString()} · CRC ${img.crcOk ? "ok" : "BAD"}',
                ),
                _kv(
                  '映射',
                  '数据 0x${MachineConst.vdiskDataBase.toRadixString(16)} · '
                      '寄存器 0x${MachineConst.vdiskRegsBase.toRadixString(16)}',
                ),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 5,
                  runSpacing: 4,
                  children: [
                    // 真机是 25 个分区，全列会撑爆面板；只显示前 8 个 + 计数。
                    for (final p in img.partitions.take(8))
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFF0E1114),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: const Color(0xFF252B32)),
                        ),
                        child: Text(
                          '${p.name}  0x${p.offset.toRadixString(16).toUpperCase()} · ${p.sizeText}',
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 9.5,
                            color: Color(0xFFA8B3BF),
                          ),
                        ),
                      ),
                    if (img.partitions.length > 8)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        child: Text(
                          '+${img.partitions.length - 8} 个分区',
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 9.5,
                            color: Color(0xFF7E8894),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  // ------------------------------------------------------------ qemu panel

  Widget _qemuPanel() {
    return _panel(
      title: 'QEMU 进程',
      expand: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _kv('可执行文件', c.qemuBin),
            _kv(
              '机器模型',
              '${MachineConst.id} · ${MachineConst.ramMb}MB · Cortex-A7',
            ),
            _kv(
              '监听 monitor',
              c.spec == null ? '上电后分配独立 socket' : 'unix:${c.spec!.monitorSock}',
            ),
            _kv('串口', 'stdio（guest ttyS0@921600 · 真车 UART0 0x9c000900）'),
            ValueListenableBuilder<KernelImage?>(
              valueListenable: c.kernel,
              builder: (_, k, _) => _kv('内核', k?.label ?? '—'),
            ),
            ValueListenableBuilder<int?>(
              valueListenable: c.pid,
              builder: (_, v, _) => _kv('PID', v?.toString() ?? '—'),
            ),
            ValueListenableBuilder<double>(
              valueListenable: c.fps,
              builder: (_, v, _) => _kv(
                '抓帧',
                '${v.toStringAsFixed(1)} fps · 失败 ${c.frameErrors}',
              ),
            ),
            ValueListenableBuilder<String>(
              valueListenable: c.lastCmd,
              builder: (_, v, _) => _kv('最近 monitor 命令', v),
            ),
            ValueListenableBuilder<int>(
              valueListenable: c.bridge.clients,
              builder: (_, n, _) => _kv(
                '串口桥',
                c.bridge.listening.value
                    ? '${c.bridge.address} · $n 个终端已连接'
                    : '未监听 ${c.bridge.error.value}',
              ),
            ),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(bottom: 6),
              dense: true,
              title: const Text(
                '完整命令行',
                style: TextStyle(fontSize: 11, color: Color(0xFF8A96A3)),
              ),
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0E1114),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: SelectableText(
                    c.spec?.shellLine() ?? '（未启动）',
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 10,
                      height: 1.5,
                      color: Color(0xFFA8B3BF),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------ log panel

  Widget _logPanel() {
    final visibleLogs = logLines
        .where((l) => enabledLogs.contains(l.kind))
        .toList();
    return _panel(
      title: '串口 + QEMU 日志',
      child: ListView.builder(
        controller: logScroll,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        itemCount: visibleLogs.length,
        itemBuilder: (_, i) {
          final l = visibleLogs[i];
          final bad = _alarm(l.text);
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 0.5),
            child: RichText(
              text: TextSpan(
                children: [
                  TextSpan(
                    text: switch (l.kind) {
                      LogKind.qemu => 'QEMU  ',
                      LogKind.serial => 'SER   ',
                      LogKind.monitor => 'MON   ',
                      LogKind.app => 'APP   ',
                      LogKind.mcu => 'MCU   ',
                    },
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 9.5,
                      color: _color(l.kind).withValues(alpha: 0.55),
                    ),
                  ),
                  TextSpan(
                    text: l.count > 1 ? '${l.text}   ×${l.count}' : l.text,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 10.5,
                      height: 1.45,
                      color: bad ? const Color(0xFFFF7B72) : _color(l.kind),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
      actions: [
        PopupMenuButton<LogKind>(
          tooltip: '日志分类',
          iconSize: 16,
          onSelected: (kind) => setState(() {
            enabledLogs.contains(kind)
                ? enabledLogs.remove(kind)
                : enabledLogs.add(kind);
          }),
          itemBuilder: (_) => [
            for (final kind in LogKind.values)
              CheckedPopupMenuItem(
                value: kind,
                checked: enabledLogs.contains(kind),
                child: Text(kind.name),
              ),
          ],
          icon: const Icon(Icons.filter_list),
        ),
        IconButton(
          tooltip: autoscroll ? '自动滚动：开' : '自动滚动：关',
          iconSize: 16,
          onPressed: () => setState(() => autoscroll = !autoscroll),
          icon: Icon(autoscroll ? Icons.vertical_align_bottom : Icons.pause),
        ),
        IconButton(
          tooltip: '清空',
          iconSize: 16,
          onPressed: () => setState(logLines.clear),
          icon: const Icon(Icons.clear_all),
        ),
        IconButton(
          tooltip: '导出日志',
          iconSize: 16,
          onPressed: _exportLogs,
          icon: const Icon(Icons.save_alt),
        ),
      ],
    );
  }

  // ------------------------------------------------------------ keys

  Widget _keyBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      decoration: const BoxDecoration(
        color: Color(0xFF181C20),
        border: Border(top: BorderSide(color: Color(0xFF2A3038))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                '操作按键',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
              ),
              const SizedBox(width: 8),
              const Text(
                '蓝标 = 仪表侧 CFCP KeyID（已实测）；橙标 = 真车由 GD32 执行，走客户端 MCU 模型',
                style: TextStyle(fontSize: 10, color: Color(0xFF7E8894)),
              ),
              const Spacer(),
              const Text(
                '真车链路：把手开关 → GD32 MCU → CFCP KeyID（/dev/ttyS1）→ cfcp-keypad → input',
                style: TextStyle(fontSize: 10, color: Color(0xFF7E8894)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          _mcuStateBar(),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < kGroups.length; i++) ...[
                Expanded(child: _keyGroup(kGroups[i])),
                if (i != kGroups.length - 1) const SizedBox(width: 16),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _keyGroup(KeyGroup g) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              g.title,
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
            ),
            const SizedBox(width: 6),
            Text(
              g.detail,
              style: const TextStyle(fontSize: 9.5, color: Color(0xFF7E8894)),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [for (final k in g.keys) _keyButton(k)],
        ),
      ],
    );
  }

  /// 电机控制器（电控）+ GD32 车身状态条。
  ///
  /// 2026-11-05：上行状态链路已闭环。按键 / 整车状态机改写 `DashTelemetry`
  /// 与 `MotorStatus`，经 `vehicle_info1/2/3` + `indicator_lamp` 上行，
  /// 由 guest 原厂 widget 自己渲染；这里只做观测，不画任何像素。
  Widget _mcuStateBar() {
    return ValueListenableBuilder<int>(
      valueListenable: c.motorRevision,
      builder: (_, _, _) => ValueListenableBuilder<McuState>(
        valueListenable: c.mcu.state,
        builder: (_, s, _) {
          return ValueListenableBuilder<ClusterPeerState>(
            valueListenable: c.clusterState,
            builder: (_, peer, _) {
              final t = c.telemetry;
              final m = t.motor;
              return Row(
                children: [
                  const Text(
                    '电控 / 车身',
                    style: TextStyle(fontSize: 10, color: Color(0xFF7E8894)),
                  ),
                  const SizedBox(width: 8),
                  _mcuChip('左转 ◀', s.leftLamp, const Color(0xFFFFC978)),
                  _mcuChip('右转 ▶', s.rightLamp, const Color(0xFFFFC978)),
                  _mcuChip('双闪', s.hazard, const Color(0xFFFFC978)),
                  _mcuChip('照明', s.highBeam, const Color(0xFF7FB2FF)),
                  _mcuChip('超车灯', s.passOn, const Color(0xFF7FB2FF)),
                  _mcuChip('定速', s.cruise, const Color(0xFF3DDC97)),
                  const SizedBox(width: 6),
                  _infoChip('TCS ${m.tc == 1 ? 'ON' : 'OFF'}'),
                  _infoChip(_modeLabel(t.driveMode)),
                  _infoChip('${t.gear == 1 ? 'P 挡' : '挡位 ${t.gear}'}'
                      ' · ${t.speed} km/h'),
                  if (m.evReady > 0) _infoChip('READY'),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      '${peer.mcuLinkUp ? '已握手' : '未握手'}'
                      ' 心跳×${peer.heartbeatCount} · ${m.summary}'
                      ' · 经 vehicle_info*/indicator_lamp 上行',
                      style: const TextStyle(
                        fontSize: 9.5,
                        color: Color(0xFF6B7580),
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  String _modeLabel(int mode) => switch (mode) {
    1 => 'ECO',
    2 => 'STREET',
    3 => 'SPORT',
    _ => '模式$mode',
  };

  Widget _infoChip(String text) => Container(
    margin: const EdgeInsets.only(right: 5),
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: const Color(0xFF1A2630),
      border: Border.all(color: const Color(0xFF34536B)),
      borderRadius: BorderRadius.circular(4),
    ),
    child: Text(
      text,
      style: const TextStyle(fontSize: 9.5, color: Color(0xFF8FC4F5)),
    ),
  );

  Widget _mcuChip(String label, bool on, Color color) {
    return Container(
      margin: const EdgeInsets.only(right: 6),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: on ? color.withValues(alpha: 0.16) : const Color(0xFF20262C),
        border: Border.all(
          color: on ? color.withValues(alpha: 0.55) : const Color(0xFF2C333B),
        ),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 9.5,
          color: on ? color : const Color(0xFF6B7580),
        ),
      ),
    );
  }

  Widget _keyButton(InstrumentKey k) {
    final down = pressedKey == k.label;
    final supported = k.supported;
    // 固件原生密码界面下，上/下/SET/BACK 原样透传给仪表，同时喂给 MCU 校验；
    // 客户端不绘制任何密码盘。
    final pwLabels = const {
      '上': PasswordKey.up,
      '下': PasswordKey.down,
      'SET': PasswordKey.set,
      'BACK': PasswordKey.back,
    };
    final pwKey = c.vehicle.passwordMode ? pwLabels[k.label] : null;
    // 自定义键有独立的**长按**语义（真车 = 长按功能码 7 切信息组），
    // 所以它的短按动作放到抬起时才发，避免按住时短按+长按各触发一次。
    final isReady = k.label == '启动';
    final isCustom = k.mcu == McuKey.custom ||
        k.mcu == McuKey.highBeam ||
        isReady;
    final isPass = k.mcu == McuKey.pass;
    var longHandled = false;

    void fire({bool long = false}) {
      c.pressInstrumentKey(k, long: long).then((hint) {
        if (hint != null && mounted) _appLog(hint);
      });
    }

    void pressDown() {
      setState(() => pressedKey = k.label);
      if (pwKey != null) {
        // ★ 真实按下，不合成 40 ms tap：固件 `KeyDelegate` 靠按住时长
        //   判定长按（BACK 3000 ms → clickLongBack → 关机）。合成 tap
        //   永远触发不了长按，这正是「长按 BACK 关机不生效」的根因。
        c.pwKeyDown(pwKey);
      } else if (!isCustom) {
        // 仪表键 → CFCP KeyID 帧；MCU 键 → 车身模型。两者都由控制器分流。
        if (isPass) {
          c.mcuKeyDown(k);
        } else {
          fire();
        }
      }
    }

    /// `fireShort` = false 时不触发短按（滑动取消 / 长按已触发）。
    void pressUp({bool fireShort = true}) {
      setState(() => pressedKey = null);
      if (pwKey != null) {
        c.pwKeyUp(pwKey);
        return;
      }
      if (isPass) {
        c.mcuKeyUp(k);
        return;
      }
      if (!isCustom || !fireShort) return;
      if (isReady) {
        _runVehicle(c.pressReady);
      } else {
        fire();
      }
    }

    void longPress() {
      setState(() => pressedKey = null);
      if (k.label == '启动') {
        _readyLongPress();
      } else if (isCustom) {
        longHandled = true;
        fire(long: true);
      }
    }

    return AnimatedContainer(
      duration: const Duration(milliseconds: 90),
      decoration: BoxDecoration(
        color: down ? const Color(0xFF2A6B52) : const Color(0xFF22282E),
        border: Border.all(
          color: down ? const Color(0xFF3DDC97) : const Color(0xFF2F3741),
        ),
        borderRadius: BorderRadius.circular(7),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(7),
        onTapDown: (supported || isReady) ? (_) => pressDown() : null,
        onTapUp: (supported || isReady)
            ? (_) => pressUp(fireShort: !longHandled)
            : null,
        onTapCancel: (supported || isReady) ? () => pressUp(fireShort: false) : null,
        onLongPress: k.hasLongPress ? longPress : null,
        onTap: (supported || isReady)
            ? () {}
            : () {
                final message = k.label == '启动'
                    ? '「启动」= Ready：请长按（按住不放）触发解锁 / 就绪 / 关机。'
                    : '「${k.label}」尚未确认原厂 MCU 协议，当前不能控制固件。';
                _appLog(message);
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text(message)));
              },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                k.label,
                style: const TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 1),
              Text(
                k.sub,
                style: const TextStyle(fontSize: 8.5, color: Color(0xFF8A96A3)),
              ),
              const SizedBox(height: 1),
              Text(
                k.label == '启动' ? '短按前进 / 长按开关机' : k.badge,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 7.5,
                  color: k.code != null
                      ? const Color(0xFF7FB2FF)
                      : const Color(0xFFFFC978),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _kv(String k, String v) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1.5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(
              k,
              style: const TextStyle(fontSize: 10.5, color: Color(0xFF7E8894)),
            ),
          ),
          Expanded(
            child: Text(
              v,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 10.5,
                color: Color(0xFFC6D0DA),
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _panel({
    required String title,
    required Widget child,
    List<Widget>? actions,
    Widget? footer,
    bool expand = true,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF181C20),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF252B32)),
      ),
      clipBehavior: Clip.antiAlias,
      // Material 放在 DecoratedBox 里面，ListTile 的墨水效果才可见
      child: Material(
        color: Colors.transparent,
        child: Column(
          children: [
            Container(
              height: 30,
              padding: const EdgeInsets.only(left: 12, right: 4),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: Color(0xFF252B32))),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 10.5,
                        letterSpacing: 0.6,
                        color: Color(0xFF8A96A3),
                      ),
                    ),
                  ),
                  ...?actions,
                ],
              ),
            ),
            if (expand) Expanded(child: child) else child,
            ?footer,
          ],
        ),
      ),
    );
  }
}
