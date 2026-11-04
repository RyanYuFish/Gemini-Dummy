// 启动链路自检（不依赖 Flutter/UI，可在纯 Dart VM 跑）。
//
//   dart run tool/boot_check.dart            # 只打印准备结果与命令行
//   dart run tool/boot_check.dart --run 6    # 真的拉起 QEMU，跑 6 秒后收尾
//
// 走的正是 Flutter 前端 `QemuController.start()` 的同一条路径：
//   BootPreparation（自建 QEMU → SPVD → 解析头 → 抽 kernel → LaunchSpec）→ Process.start
// 所以这里通过，前端点「启动」也就能通过。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ae5i_emu/emu/machine.dart';
import 'package:ae5i_emu/emu/paths.dart';

Future<void> main(List<String> args) async {
  final runIdx = args.indexOf('--run');
  final seconds = runIdx >= 0 && runIdx + 1 < args.length
      ? (int.tryParse(args[runIdx + 1]) ?? 5)
      : 0;

  final prep = BootPreparation.prepare(kernelPath: _opt(args, '--kernel'));
  for (final s in prep.steps) {
    stdout.writeln('· $s');
  }
  if (!prep.ok) {
    stdout.writeln('\n✗ ${prep.error}');
    exit(1);
  }

  final spec = prep.spec!;
  stdout.writeln('\n\$ ${spec.shellLine()}\n');
  if (seconds <= 0) return;

  stdout.writeln('拉起 QEMU，观测 ${seconds}s …');
  final proc = await Process.start(
    spec.qemuBin,
    spec.argv(),
    workingDirectory: LabPaths.lab,
    environment: {...Platform.environment, ...spec.env()},
  );
  final out = StringBuffer();
  final err = StringBuffer();
  final subOut = proc.stdout.transform(utf8.decoder).listen(out.write);
  final subErr = proc.stderr.transform(utf8.decoder).listen(err.write);

  var exited = false;
  final exitCode = proc.exitCode.then((c) {
    exited = true;
    return c;
  });
  await Future.any([exitCode, Future.delayed(Duration(seconds: seconds))]);
  if (!exited) proc.kill();

  await Future.delayed(const Duration(milliseconds: 200));
  await subOut.cancel();
  await subErr.cancel();

  stdout.writeln('--- QEMU stderr ---');
  stdout.writeln(err.isEmpty ? '(空)' : err.toString().trim());
  stdout.writeln('--- guest serial (stdout) ---');
  stdout.writeln(out.isEmpty ? '(空)' : out.toString().trim());
  if (exited) stdout.writeln('QEMU 已自行退出，code=${await exitCode}');
}

String? _opt(List<String> args, String name) {
  final i = args.indexOf(name);
  return (i >= 0 && i + 1 < args.length) ? args[i + 1] : null;
}
