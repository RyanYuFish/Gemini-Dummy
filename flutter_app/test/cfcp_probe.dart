// 诊断用：抓取 guest（内核 CFCP 驱动）→ 客户端方向的真实字节。
//
//   AE5I_CFCP_TRACE=1 flutter test --no-pub test/cfcp_probe.dart
//
// 目的：搞清 `cfcp_ack_q_work_handl ... resend_times is 3, del list:cmdid:0x75`
// 到底是「guest 的 0x75 请求没被我们 ACK」还是「guest 的 ACK 没人理」。
// 只有拿到真实入站帧，才能确定 ACK 帧的形态，而不是靠猜。
import 'dart:async';
import 'dart:io';

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
    'probe: capture guest -> client CFCP bytes',
    () async {
      final controller = QemuController();
      final lines = <String>[];
      final sub = controller.log.stream.listen((l) {
        lines.add(l.text);
        stdout.writeln('[${l.kind.name}] ${l.text}');
      });
      try {
        await controller.powerOn();
        await waitUntil(
          () => controller.vehicleState.value == VehicleState.locked,
          const Duration(seconds: 170),
        );
        final unlock = await controller.swipeCard();
        expect(unlock.accepted, isTrue);
        // 留足时间：基线 7 帧 + 心跳若干 + guest 重传窗口（3 次）。
        await Future<void>.delayed(const Duration(seconds: 15));

        final rx = lines.where((l) => l.contains('CFCP ←')).toList();
        stdout.writeln('\n===== CFCP RX SUMMARY =====');
        stdout.writeln('rx lines: ${rx.length}');
        for (final l in rx.take(40)) {
          stdout.writeln(l);
        }
        stdout.writeln('===== PEER PROPS (SoC → MCU) =====');
        final props = controller.peerProps;
        for (final e in props.entries) {
          stdout.writeln(
            'prop=0x${e.key.toRadixString(16).padLeft(8, '0')} value=${e.value}',
          );
        }
        stdout.writeln('----- counters -----');
        stdout.writeln('rx frames: ${controller.cfcpRxFrames}');
        stdout.writeln('ack sent : ${controller.cfcpAckSent}');
        stdout.writeln('===== END =====\n');
      } finally {
        await controller.stop();
        await sub.cancel();
        controller.dispose();
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
