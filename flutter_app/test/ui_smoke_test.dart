// Headless smoke test: the whole UI tree builds and lays out without Xcode.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ae5i_emu/main.dart';

void main() {
  testWidgets('main window renders all three regions', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: const EmuPage(autoStart: false),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('ZEEHO AE5i 仪表模拟器'), findsOneWidget);
    expect(find.textContaining('仪表画面'), findsOneWidget);
    expect(find.textContaining('串口 + QEMU 日志'), findsOneWidget);
    expect(find.text('操作按键'), findsOneWidget);

    // every handlebar key from the real vehicle is present
    for (final k in kKeys) {
      expect(find.text(k.label), findsWidgets, reason: 'key ${k.label}');
    }
    expect(kGroups.length, 2);
    expect(
      kGroups[0].keys.length,
      11,
      reason: '10 left controls; turn stalk split L/R',
    );
    expect(
      kGroups[1].keys.length,
      4,
      reason: '3 right controls; gear rocker split +/-',
    );
    expect(find.text('左把手'), findsOneWidget);
    expect(find.text('右把手'), findsOneWidget);

    for (final name in ['上', '下', 'SET', 'BACK', '双闪', '拨杆 ◀', '加档']) {
      final key = tester.widget<InkWell>(
        find
            .ancestor(of: find.text(name), matching: find.byType(InkWell))
            .first,
      );
      expect(key.onTapDown, isNotNull, reason: '$name press');
      expect(key.onTapUp, isNotNull, reason: '$name release');
    }
    // 「启动」是唯一没有直达通道的按键：只能长按走整车状态机。
    final ready = tester.widget<InkWell>(
      find.ancestor(of: find.text('启动'), matching: find.byType(InkWell)).first,
    );
    expect(ready.onTapDown, isNull, reason: 'Ready 只认长按');
    expect(ready.onLongPress, isNotNull, reason: '长按 Ready 走整车状态机');
    expect(ready.onTap, isNotNull, reason: '单击给出长按提示');

    // 翻转类 MCU 键不能挂长按处理器，否则按住 = 短按 + 长按各翻一次。
    final hazard = tester.widget<InkWell>(
      find.ancestor(of: find.text('双闪'), matching: find.byType(InkWell)).first,
    );
    expect(hazard.onLongPress, isNull, reason: '双闪是翻转语义');
    expect(hazard.onTapDown, isNotNull, reason: '双闪按下即翻转');

    // MCU 状态条：仪表侧 11 个 KeyID 之外的键由客户端 MCU 模型承载
    expect(find.text('模拟 MCU 车身'), findsOneWidget);
    // 方向更正后（2026-11-02，见 EMULATION.md §29）：显示 guest（SoC）广播回来的
    // 仪表真实状态（灯态位图 / 档位 / 状态字节），而不是我们自己臆造的上报值。
    expect(find.textContaining('SoC 灯态'), findsOneWidget);
    expect(find.textContaining('SoC 档位'), findsOneWidget);
    expect(find.textContaining('SoC 状态'), findsOneWidget);
    expect(find.textContaining('SoC 广播'), findsOneWidget);

    // QEMU panel surfaces the process itself (PID / cmdline / monitor)
    expect(find.textContaining('QEMU 进程'), findsOneWidget);
    expect(find.textContaining('上电后分配独立 socket'), findsOneWidget);
    // 整车流程面板：上电 → 刷卡/App/Ready 解锁 → 关机 → 拔电
    expect(find.text('刷 NFC 卡'), findsOneWidget);
    expect(find.text('App 解锁'), findsOneWidget);
    expect(find.text('Ready 长按'), findsOneWidget);
    expect(find.text('拔电'), findsOneWidget);
    expect(find.textContaining('下一步：'), findsOneWidget);
    await tester.tap(find.text('启动'));
    await tester.pump();
    expect(find.textContaining('请长按'), findsWidgets);
  });
  testWidgets('log export sends complete content to native save panel', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    MethodCall? captured;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('ae5i/files'),
      (call) async {
        captured = call;
        return '/tmp/acceptance.log';
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('ae5i/files'),
        null,
      ),
    );
    await tester.pumpWidget(MaterialApp(home: const EmuPage(autoStart: false)));
    await tester.tap(find.byTooltip('导出日志'));
    await tester.pumpAndSettle();
    expect(captured!.method, 'saveLog');
    expect(captured!.arguments['text'], contains('AE5I emulator log'));
    expect(find.text('日志已导出：/tmp/acceptance.log'), findsWidgets);
    await tester.pumpWidget(const SizedBox());
  });
}
