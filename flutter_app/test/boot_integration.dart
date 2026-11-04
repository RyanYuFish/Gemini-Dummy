// Run explicitly: flutter test --no-pub test/boot_integration.dart
// Uses the real QEMU model and AE5I software-display SPVD; takes ~2 minutes.
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
      throw TimeoutException('guest did not reach expected state');
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
}

Future<void> waitForPaint(
  ui.Image? Function() current,
  Duration timeout,
) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final copy = current()?.clone();
    if (copy != null) {
      final data = await copy.toByteData(format: ui.ImageByteFormat.rawRgba);
      copy.dispose();
      if (data != null) {
        for (var i = 0; i < data.lengthInBytes; i += 4) {
          if (data.getUint8(i) != 0 ||
              data.getUint8(i + 1) != 0 ||
              data.getUint8(i + 2) != 0) {
            return;
          }
        }
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  throw TimeoutException('framebuffer remained black');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'AE5I QEMU framebuffer and CFCP navigation work through controller',
    () async {
      final controller = QemuController();
      final lines = <String>[];
      ui.Image? latest;
      final logFile = File(
        '${Directory.current.parent.parent.path}/dist/qemu-ae5i/client-acceptance.log',
      ).openWrite();
      final logSub = controller.log.stream.listen((line) {
        lines.add(line.text);
        logFile.writeln('[${line.kind.name}] ${line.text}');
      });
      final frameSub = controller.frames.stream.listen((frame) {
        latest?.dispose();
        latest = frame;
      });
      try {
        await controller.powerOn();
        expect(controller.running.value, isTrue);
        expect(controller.spec!.cfcpPort, isNot(4502));
        expect(controller.spec!.monitorSock, contains('ae5i-session-'));
        expect(controller.spec!.framePath, contains('ae5i-session-'));
        await waitUntil(
          () =>
              lines.any(
                (line) => line.contains('dashclustoractivity.cpp 62'),
              ) &&
              latest != null,
          const Duration(seconds: 170),
        );
        await waitForPaint(() => latest, const Duration(seconds: 30));
        // 上电后仪表停在「未解锁（待机）」：framebuffer 已能出画面，但客户端
        // 按真车逻辑保持黑屏待机——仪表点亮要等解锁（车辆启动）。
        await waitUntil(
          () => controller.vehicleState.value == VehicleState.locked,
          const Duration(seconds: 60),
        );
        expect(controller.vehicleState.value, VehicleState.locked);
        // 解锁：刷卡唤醒 → 车辆启动，此刻仪表才点亮。模型在解锁时重放开机动画。
        final unlock = await controller.swipeCard();
        expect(unlock.accepted, isTrue);
        expect(controller.vehicleState.value, VehicleState.unlocked);
        // 延迟的开机动画在解锁瞬间被触发：先 animating=true，再交还 Launcher。
        await waitUntil(
          () => controller.animating.value,
          const Duration(seconds: 20),
        );
        await waitUntil(
          () => !controller.animating.value,
          const Duration(seconds: 60),
        );
        await controller.sendKeyEvent('上', 0xd2, true);
        await Future<void>.delayed(const Duration(milliseconds: 250));
        await controller.sendKeyEvent('上', 0xd2, false);
        await waitUntil(
          () =>
              lines.any((line) => line.contains('keypress:1100227')) &&
              lines.any((line) => line.contains('keyprelease:1100227')),
          const Duration(seconds: 20),
        );
        expect(latest!.width, 1024);
        expect(latest!.height, 600);
        // 已解锁 → 长按 Ready → 就绪；再长按 Ready = 关机。
        await controller.longPressReady();
        expect(controller.vehicleState.value, VehicleState.ready);
        await controller.longPressReady();
        expect(controller.vehicleState.value, VehicleState.poweringOff);
        await waitUntil(
          () => !controller.running.value,
          const Duration(seconds: 45),
        );
        expect(lines.any((l) => l.contains('guest 已报告关机/停机完成')), isTrue);
        expect(controller.vehicleState.value, VehicleState.poweredOff);
        // 正常下电之后才允许拔电。
        final unplug = await controller.unplugPower();
        expect(unplug.accepted, isTrue);
        expect(controller.vehicleState.value, VehicleState.off);
        final report = File(
          '${Directory.current.parent.parent.path}/dist/qemu-ae5i/client-acceptance.txt',
        );
        report.writeAsStringSync(
          'Session: ${controller.spec!.monitorSock}\n'
          'CFCP: ${controller.spec!.cfcpPort}\n'
          'Framebuffer: 1024x600, non-black\n'
          'BootAnimation: deferred to unlock (SP_WAKE_FILE); replayed on swipe, '
          'then handed to Launcher\n'
          'Navigation: up press/release observed by Launcher\n'
          'Vehicle flow: powerOn -> booting(mcu) -> locked(standby) -> '
          'swipe -> unlocked(wake+anim) -> ready -> poweringOff -> '
          'poweredOff -> unplug off\n'
          'Poweroff: guest reported halt; QEMU exited\n',
        );
      } finally {
        await controller.stop();
        await logSub.cancel();
        await logFile.close();
        await frameSub.cancel();
        latest?.dispose();
        controller.dispose();
      }
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
