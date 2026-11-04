// CFCP 链路取证：确认「客户端发进去的属性帧，guest 到底有没有收」。
//
//   AE5I_CFCP_TRACE=1 flutter test --no-pub test/cfcp_link_probe.dart
//
// 判据：
//   * 只看 guest 主动回给我们的帧（`CFCP ← frame#...`）；
//   * 先静默 5 秒数「无刺激时的入站帧」，再发 N 条属性帧，看入站帧是否随之增加；
//   * 若发了 N 条而回帧数不变，说明 guest 对 MCU 方向的属性帧完全不作应答。
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:ae5i_emu/emu/controller.dart';
import 'package:ae5i_emu/emu/vehicle.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> waitUntil(bool Function() condition, Duration timeout) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('condition not met');
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'probe: does the guest answer property frames coming from the MCU side',
    () async {
      final controller = QemuController();
      ui.Image? latest;
      final frameSub = controller.frames.stream.listen((f) {
        latest?.dispose();
        latest = f;
      });
      final rx = <String>[];
      final all = <String>[];
      final logSub = controller.log.stream.listen((l) {
        all.add('[${l.kind.name}] ${l.text}');
        if (l.text.contains('CFCP ←')) rx.add(l.text);
      });

      try {
        await controller.powerOn();
        await waitUntil(
          () => controller.vehicleState.value == VehicleState.locked,
          const Duration(seconds: 170),
        );
        expect((await controller.swipeCard()).accepted, isTrue);
        await waitUntil(
          () => !controller.animating.value,
          const Duration(seconds: 90),
        );

        // 1) 静默观察 5 秒：不刺激时的入站帧基线。
        final quietStart = controller.cfcpRxFrames;
        final quietRxStart = rx.length;
        await Future<void>.delayed(const Duration(seconds: 5));
        final quietFrames = controller.cfcpRxFrames - quietStart;
        stdout.writeln('静默 5s：入站帧 $quietFrames，ACK 已发 '
            '${controller.cfcpAckSent}');
        for (final l in rx.skip(quietRxStart).take(12)) {
          stdout.writeln('  $l');
        }

        // 2) 发 6 条属性帧，逐条间隔 0.3 s，再等 3 s 看入站增量。
        final mark = controller.cfcpRxFrames;
        final markRx = rx.length;
        const probes = [
          0x21417310,
          0x21400002,
          0x21407059,
          0x27400027,
          0x21701003,
          0x21407072,
        ];
        for (final p in probes) {
          await controller.sendVehicleProp(p, intValue: 1, log: false);
          await Future<void>.delayed(const Duration(milliseconds: 300));
        }
        await Future<void>.delayed(const Duration(seconds: 3));
        final afterFrames = controller.cfcpRxFrames - mark;
        stdout.writeln('');
        stdout.writeln('发 6 条属性帧后入站帧增量：$afterFrames');
        for (final l in rx.skip(markRx)) {
          stdout.writeln('  $l');
        }
        stdout.writeln('');
        stdout.writeln('累计：入站 ${controller.cfcpRxFrames} 帧，'
            '回 ACK ${controller.cfcpAckSent} 个，'
            '对端属性表 ${controller.peerProps}');

        // 3) 对照组：发一条按键帧，Launcher 若有反应说明按键通道是通的。
        await controller.sendKeyEvent('上', 0xd2, true);
        await Future<void>.delayed(const Duration(milliseconds: 250));
        await controller.sendKeyEvent('上', 0xd2, false);
        await Future<void>.delayed(const Duration(seconds: 2));
        final keySeen = all.any((l) => l.contains('keypress:1100227'));
        stdout.writeln('按键帧被 Launcher 收到：$keySeen');

        File(
          '${Directory.current.parent.parent.path}/dist/qemu-ae5i/'
          'cfcp-link-probe.txt',
        ).writeAsStringSync(
          'quietRx=$quietFrames afterProbeRx=$afterFrames '
          'totalRx=${controller.cfcpRxFrames} acks=${controller.cfcpAckSent} '
          'peerProps=${controller.peerProps} keySeen=$keySeen\n\n'
          '${rx.join('\n')}',
        );
      } finally {
        await controller.stop();
        await frameSub.cancel();
        await logSub.cancel();
        latest?.dispose();
        controller.dispose();
      }
    },
    timeout: const Timeout(Duration(minutes: 6)),
  );
}
