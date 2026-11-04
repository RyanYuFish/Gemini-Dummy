// 按键表回归：锁住「设备到底认哪些 KeyID」这条证据链。
//
// 数据来源（见 emu/keys.dart 顶部注释）：
//   * 设备 /application/keymap/keymap.data（QMAP v1，602 条）在 0xc0..0xff 只有
//     11 条；
//   * 逐键实测 Launcher 动作名。
// 任何"想当然"地把 0xc0..0xff 之外的 KeyID 当成可用，都会在这里挂掉。

import 'package:flutter_test/flutter_test.dart';
import 'package:ae5i_emu/emu/keys.dart';
import 'package:ae5i_emu/emu/mcu.dart';

void main() {
  test('仪表侧 KeyID 与设备 keymap.data 的 11 条完全一致', () {
    expect(ClusterKeys.all.toSet(), {
      0xc8,
      0xc9,
      0xcf,
      0xd1,
      0xd2,
      0xd3,
      0xd4,
      0xd5,
      0xd6,
      0xd7,
      0xdf,
    });
    expect(ClusterKeys.all.length, 11);
  });

  test('导航键映射到 Launcher 实测的动作名', () {
    expect(ClusterKeys.actionName(ClusterKeys.up), 'app_key_up');
    expect(ClusterKeys.actionName(ClusterKeys.down), 'app_key_down');
    expect(ClusterKeys.actionName(ClusterKeys.right), 'app_key_right');
    expect(ClusterKeys.actionName(ClusterKeys.left), 'app_key_left');
    expect(ClusterKeys.actionName(ClusterKeys.ota), 'app_key_ota');
    expect(ClusterKeys.actionName(ClusterKeys.ota960), 'app_key_960');
    // 五个"有映射但没命名动作"的键不给名字：它们按下后画面无变化。
    for (final id in ClusterKeys.reserved) {
      expect(ClusterKeys.actionName(id), isNull, reason: 'KeyID 0x$id');
    }
  });

  test('面板上每个键要么走仪表帧，要么走 MCU 模型（Ready 例外）', () {
    for (final k in kKeys) {
      if (k.label == '启动') {
        // Ready 由整车状态机的长按路径处理，不是 CFCP 帧也不是 MCU 模型。
        expect(k.code, isNull);
        expect(k.mcu, isNull);
        expect(k.supported, isFalse);
        continue;
      }
      expect(k.supported, isTrue, reason: '${k.label} 必须有确定行为');
      expect(k.code != null || k.mcu != null, isTrue, reason: '${k.label} 缺少 code/mcu');
      expect(k.code == null || k.mcu == null, isTrue, reason: '${k.label} 不能两路都占');
    }
  });

  test('上/下/SET/BACK 用的是实测 KeyID，不是占位值', () {
    InstrumentKey byLabel(String label) =>
        kKeys.firstWhere((k) => k.label == label);

    expect(byLabel('上').code, 0xd2);
    expect(byLabel('下').code, 0xd3);
    expect(byLabel('SET').code, 0xd4); // app_key_right：确认方向
    expect(byLabel('BACK').code, 0xd5); // app_key_left：返回方向
    expect(byLabel('上').badge, 'CFCP 0xd2');
    expect(byLabel('双闪').badge, 'MCU');
  });

  test('物理键位数量与实车一致（左 11 / 右 4，档位拨杆与转向拨杆各拆两键）', () {
    expect(kGroups.length, 2);
    expect(kGroups[0].keys.length, 11);
    expect(kGroups[1].keys.length, 4);
  });

  test('除导航四键外，其余把手键都落在 MCU 侧', () {
    final cluster = kKeys.where((k) => k.code != null).map((k) => k.label).toSet();
    expect(cluster, {'上', '下', 'SET', 'BACK'});
    final mcu = kKeys.where((k) => k.mcu != null).map((k) => k.mcu).toSet();
    expect(mcu, containsAll(McuKey.values));
  });

  test('只有自定义键和启动有长按语义（否则翻转类按键会连开连关）', () {
    final long = kKeys.where((k) => k.hasLongPress).map((k) => k.label).toSet();
    expect(long, {'自定义键', '启动'});
    // 双闪/转向这类翻转键必须逐次按下才翻转一次。
    for (final label in ['双闪', '拨杆 ◀', '拨杆 ▶', '照明', '定速']) {
      expect(
        kKeys.firstWhere((k) => k.label == label).hasLongPress,
        isFalse,
        reason: label,
      );
    }
  });
}
