// 命令行端到端验收：起自建 QEMU + DashUpFeeder，检查画面是否由固件自身
// 渲染出 P 档主界面（非黑 ≈60%，茶青 ≈45%）。
//
//   dart run tool/dash_up_check.dart --frames    # 输出帧 hex，与 dash_up.py 比对
//   dart run tool/dash_up_check.dart             # 端到端跑 60 s，打印逐秒统计
//   dart run tool/dash_up_check.dart --duration 90 --out /tmp/check.ppm
//
// 纯 Dart（无 Flutter），所以可以在 CI / 无显示环境里跑。

// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:ae5i_emu/emu/cfcp.dart';
import 'package:ae5i_emu/emu/dash_up.dart';
import 'package:ae5i_emu/emu/machine.dart';
import 'package:ae5i_emu/emu/paths.dart';
import 'package:ae5i_emu/emu/ppm.dart';

String _hex(List<int> b) =>
    b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();

/// --frames：按与 tools/dash_up.py 相同的顺序输出帧 hex，供 diff 校验。
void _dumpFrames() {
  final t = DashTelemetry();
  final frames = <Uint8List>[
    ...dashBootFrames(t),
    dashSyncFrame(true),
    dashVi1Frame(t),
    dashVi2Frame(t, gear: 0),
    dashVi2Frame(t, gear: 1),
    dashVi3Frame(t),
    dashBattFrame(t),
    dashOdoFrame(t),
    dashTripFrame(t),
    // 固定时间的 RTC 与固定位图的 lamp，便于逐字节比对。
    dashPropFrame(DashProp.rtc, [26, 11, 5, 6, 14, 5]),
    dashLampFrame(DashTelemetry(lampHex: '01'))!,
  ];
  for (final f in frames) {
    print(_hex(f));
  }
}

/// 读一帧 PPM，返回 (非黑占比, 茶青占比)，都是 0.0–1.0。
({double nonblack, double teal}) _stats(Uint8List b) {
  final p = parsePpm(b);
  if (p == null) return (nonblack: 0, teal: 0);
  final rgba = p.rgba;
  final n = p.width * p.height;
  var nb = 0;
  var teal = 0;
  for (var i = 0; i < n; i++) {
    final o = i * 4;
    final r = rgba[o], g = rgba[o + 1], bl = rgba[o + 2];
    if (r + g + bl > 10) nb++;
    if (g >= r && bl >= r && (g + bl) > 40) teal++;
  }
  return (nonblack: nb / n, teal: teal / n);
}

int _indexOfMagic(List<int> b) {
  for (var i = 0; i + 3 < b.length; i++) {
    if (b[i] == 0xFE && b[i + 1] == 0x5A && b[i + 2] == 0xAA && b[i + 3] == 0xA5) {
      return i;
    }
  }
  return -1;
}

int _findTail(List<int> b) {
  for (var i = 14; i + 2 < b.length; i++) {
    if (b[i] == 0xA5 && b[i + 1] == 0x55 && b[i + 2] == 0x5A) return i;
  }
  return -1;
}

Future<void> main(List<String> args) async {
  if (args.contains('--frames')) {
    _dumpFrames();
    return;
  }
  var duration = 60;
  var outPath = '/tmp/dash_up_check.ppm';
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--duration' && i + 1 < args.length) {
      duration = int.tryParse(args[i + 1]) ?? duration;
    }
    if (args[i] == '--out' && i + 1 < args.length) outPath = args[i + 1];
  }

  final dir = Directory.systemTemp.createTempSync('dash-up-check-');
  final prep = BootPreparation.prepare(kernelOutputPath: '${dir.path}/kernel.bin');
  for (final s in prep.steps) {
    print('PREP $s');
  }
  if (!prep.ok) {
    stderr.writeln('预检失败：${prep.error}');
    exit(2);
  }

  final reservation = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = reservation.port;
  await reservation.close();
  final base = prep.spec!;
  final framePath = '${dir.path}/frame.ppm';
  final spec = LaunchSpec(
    qemuBin: base.qemuBin,
    kernel: base.kernel,
    spvd: base.spvd,
    append: base.append,
    cfcpPort: port,
    monitorSock: '${dir.path}/monitor.sock',
    framePath: framePath,
    bootAnim: base.bootAnim,
    wakeFile: base.bootAnim != null ? '${dir.path}/wake' : null,
    shutdownWakeFile: base.bootAnim != null ? '${dir.path}/shutdown-wake' : null,
    extraEnv: base.extraEnv,
  );

  final qemuLog = File('${dir.path}/qemu.log').openWrite();
  final proc = await Process.start(
    spec.qemuBin,
    spec.argv(),
    workingDirectory: LabPaths.lab,
    environment: {...Platform.environment, ...spec.env()},
  );
  // 保存订阅：收尾时先 cancel 再 close，否则 QEMU 退出瞬间的最后几段
  // stdout/stderr 会在 IOSink 关闭后触发 "Bad state: StreamSink is closed"。
  final outSub = proc.stdout.listen((d) => qemuLog.add(d));
  final errSub = proc.stderr.listen((d) => qemuLog.add(d));
  print('QEMU pid=${proc.pid} cfcpPort=$port frame=$framePath');

  Socket? sock;
  for (var i = 0; i < 30 && sock == null; i++) {
    try {
      sock = await Socket.connect(InternetAddress.loopbackIPv4, port);
    } catch (_) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
  }
  if (sock == null) {
    stderr.writeln('连不上 CFCP 端口 $port');
    proc.kill();
    await qemuLog.close();
    exit(3);
  }
  final socket = sock;
  var acks = 0;
  var rxFrames = 0;
  final rx = <int>[];
  socket.listen((data) {
    rx.addAll(data);
    while (true) {
      final i = _indexOfMagic(rx);
      if (i < 0) {
        if (rx.length > 3) rx.removeRange(0, rx.length - 3);
        break;
      }
      if (i > 0) rx.removeRange(0, i);
      if (rx.length < 14) break;
      final end = _findTail(rx);
      if (end < 0) break;
      final frame = rx.sublist(0, end + 3);
      rx.removeRange(0, end + 3);
      rxFrames++;
      if (frame[4] != kCfcpTypeAck) {
        socket.add(cfcpAckFrame());
        acks++;
      }
    }
  });

  var lastNonblack = 0.0;
  var lastTeal = 0.0;
  ({double nonblack, double teal}) sample() {
    try {
      final f = File(framePath);
      if (!f.existsSync() || f.lengthSync() <= 1024) {
        return (nonblack: lastNonblack, teal: lastTeal);
      }
      final s = _stats(f.readAsBytesSync());
      lastNonblack = s.nonblack;
      lastTeal = s.teal;
      return s;
    } catch (_) {
      return (nonblack: lastNonblack, teal: lastTeal);
    }
  }

  // 进场动画采样：enter 之后 3 s 内每 100 ms 记一次非黑占比。数值逐步变化
  // 说明固件自己的 Animation_Pstart_init() 确实在播（整车从右下角放大滑入），
  // 而不是"直接跳到静态终帧"。
  final animSamples = <double>[];
  final feeder = DashUpFeeder(
    send: (f) async {
      socket.add(f);
      await socket.flush();
    },
    paintedPct: () => sample().nonblack,
    onLog: (s) => print('LOG  $s'),
    onPhase: (p, m) {
      print('PHASE ${p.name}: $m');
      if (p == DashUpPhase.enter) {
        unawaited(() async {
          for (var i = 0; i < 30; i++) {
            animSamples.add(sample().nonblack);
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
        }());
      }
    },
  );
  unawaited(feeder.start());

  final started = DateTime.now();
  var peakNonblack = 0.0;
  var peakTeal = 0.0;
  while (DateTime.now().difference(started).inSeconds < duration) {
    await Future<void>.delayed(const Duration(seconds: 3));
    final s = sample();
    if (s.nonblack > peakNonblack) peakNonblack = s.nonblack;
    if (s.teal > peakTeal) peakTeal = s.teal;
    final t = DateTime.now().difference(started).inSeconds;
    print('[${t}s] nonblack=${(s.nonblack * 100).toStringAsFixed(2)}% '
        'teal=${(s.teal * 100).toStringAsFixed(2)}% '
        'acks=$acks rx=$rxFrames phase=${feeder.phase.name}');
  }

  final finalStats = sample();
  try {
    File(framePath).copySync(outPath);
    print('frame saved: $outPath');
  } catch (e) {
    print('frame save failed: $e');
  }
  print('FINAL nonblack=${(finalStats.nonblack * 100).toStringAsFixed(2)}% '
      'teal=${(finalStats.teal * 100).toStringAsFixed(2)}% '
      'peak=${(peakNonblack * 100).toStringAsFixed(2)}%/${(peakTeal * 100).toStringAsFixed(2)}% '
      'acks=$acks rx=$rxFrames entered=${feeder.entered}');
  print('ANIM  ${animSamples.length} samples, nonblack% = '
      '${animSamples.map((v) => (v * 100).toStringAsFixed(1)).join(' ')}');

  feeder.stop();
  socket.destroy();
  proc.kill();
  await outSub.cancel();
  await errSub.cancel();
  await qemuLog.close();
  final ok = peakNonblack >= 0.45 && peakTeal >= 0.30;
  print(ok ? 'RESULT PASS' : 'RESULT FAIL');
  exit(ok ? 0 : 1);
}
