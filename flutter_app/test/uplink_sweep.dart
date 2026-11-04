// 上行（MCU→SoC）帧格式扫描。
//
// 背景：帧布局已由 CFCP 内核模块字段描述符表解出（见 lib/emu/cfcp.dart 注释）：
//   Header fe5aaaa5 | FRAME0 | FRAME1 | cmd u32 | dataLen u16 | DATA | chk | a5555a
// FRAME0 的 bit7 = is_response，bit6..4 = type(1..4)，bit3..0 = ACK 模式。
//
// 已确认下行属性帧 = FRAME0 0x11 / FRAME1 0x02 / cmd 0x00010175 / DATA=prop+sub+value。
// 本探针扫 (FRAME0, FRAME1, 命令字) 组合，找**上行**用哪一组：
//   判据① guest 是否回 ACK（说明帧格式合法并被驱动接受）
//   判据② guest 日志是否出现**新形态**行（说明进了用户态某个槽）
//   判据③ framebuffer 是否变化
//
//   AE5I_CFCP_TRACE=1 flutter test --no-pub test/uplink_sweep.dart
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:ae5i_emu/emu/cfcp.dart';
import 'package:ae5i_emu/emu/controller.dart';
import 'package:ae5i_emu/emu/vehicle.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> waitUntil(bool Function() condition, Duration timeout) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) throw TimeoutException('condition not met');
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
}

int paintedNonBg(Uint8List a) {
  var n = 0;
  for (var i = 0; i + 2 < a.length; i += 4) {
    if (a[i] > 8 || a[i + 1] > 8 || a[i + 2] > 8) n++;
  }
  return n;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('uplink sweep: find the MCU→SoC frame variant', () async {
    final controller = QemuController();
    ui.Image? latest;
    final frameSub = controller.frames.stream.listen((f) {
      latest?.dispose();
      latest = f;
    });
    final ackCount = <int>[0];
    final logShapes = <String>{};
    final newLines = <String>[];
    final logSub = controller.log.stream.listen((l) {
      final t = l.text;
      if (t.contains('(ACK)')) ackCount[0]++;
      // 只关心 guest 侧（serial）里与 IPC/MCUCOM 相关的行
      final shape = t.length > 70 ? t.substring(0, 70) : t;
      if (t.contains('ipcModule') ||
          t.contains('mcucom') ||
          t.contains('MCUCOM') ||
          t.contains('DashClustor') ||
          t.contains('[CFCP]')) {
        if (!logShapes.contains(shape)) {
          logShapes.add(shape);
          newLines.add(t);
        }
      }
    });

    Future<Uint8List?> grab() async {
      final img = latest?.clone();
      if (img == null) return null;
      final d = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
      img.dispose();
      return d?.buffer.asUint8List();
    }

    try {
      await controller.powerOn();
      await waitUntil(
        () => controller.vehicleState.value == VehicleState.locked,
        const Duration(seconds: 170),
      );
      expect((await controller.swipeCard()).accepted, isTrue);
      await Future<void>.delayed(const Duration(seconds: 22));
      controller.bleConnected.value = true;
      controller.tboxOnline.value = true;
      expect((await controller.longPressReady()).accepted, isTrue);
      await Future<void>.delayed(const Duration(seconds: 10));

      // 35 字节 ride-info 记录：BE16 标签 0xCF01 + 33 B 负载
      final payload = <int>[0xcf, 0x01];
      for (var i = 0; i < 33; i++) {
        payload.add((0x40 + i) & 0xff);
      }

      stdout.writeln('基线 ACK=${ackCount[0]} 已知日志形态=${logShapes.length} '
          'painted=${paintedNonBg((await grab())!)}');

      final hits = <String>[];
      for (final f0 in [0x11, 0x21, 0x31, 0x41]) {
        for (final f1 in [0x01, 0x02, 0x03, 0x08]) {
          for (final cmdByte in [0x74, 0x75, 0x76, 0x70, 0x71, 0x72, 0x01]) {
            final cmd = 0x00010100 | cmdByte;
            final ackBefore = ackCount[0];
            final shapesBefore = logShapes.length;
            final linesBefore = newLines.length;
            final pBefore = paintedNonBg((await grab())!);

            await controller.sendRawFrame(
              cfcpBuildFrame(
                frame0: f0,
                frame1: f1,
                cmd: cmd,
                data: payload,
              ),
            );
            await Future<void>.delayed(const Duration(milliseconds: 450));

            final acked = ackCount[0] > ackBefore;
            final newShape = logShapes.length > shapesBefore;
            final painted = paintedNonBg((await grab())!);
            final pix = (painted - pBefore).abs() > 40;

            if (acked || newShape || pix) {
              final tag = [
                if (acked) 'ACK',
                if (newShape) '新日志',
                if (pix) '画面$pBefore→$painted',
              ].join('+');
              final line = 'f0=0x${f0.toRadixString(16)} '
                  'f1=0x${f1.toRadixString(16)} cmd=0x${cmd.toRadixString(16)} '
                  '→ $tag';
              hits.add(line);
              stdout.writeln('  $line');
              for (var i = linesBefore; i < newLines.length && i < linesBefore + 3; i++) {
                stdout.writeln('      │ ${newLines[i]}');
              }
            }
          }
        }
      }

      stdout.writeln('\n===== 命中汇总（${hits.length} / 112）=====');
      for (final h in hits) {
        stdout.writeln('  $h');
      }
      if (hits.isEmpty) {
        stdout.writeln('  （全部组合既无 ACK、也无新日志、也无画面变化）');
      }
    } finally {
      await controller.stop();
      await frameSub.cancel();
      await logSub.cancel();
      latest?.dispose();
      controller.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 20)));
}
