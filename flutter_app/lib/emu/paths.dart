// 路径与可执行文件解析。
//
// 一条硬规则：**只用自建 QEMU**。系统 Homebrew 的 qemu-system-arm 没有
// sunplus-sp8368 机器模型，混用会得到 "unsupported machine type"，
// 所以这里找不到自建产物时返回 null，绝不回落到 /opt/homebrew。

import 'dart:io';

const String kMonSock = '/tmp/ae5i-mon.sock';
const String kFramePpm = '/tmp/ae5i-ui-frame.ppm';
const int kCfcpPort = 4502;

/// AE5I 仪表屏：1024×600（≈16:9，取自设备 runtime_cfg 的 UI_width/UI_height）。
const int kScreenW = 1024;
const int kScreenH = 600;

class LabPaths {
  LabPaths._();

  static const String projectRoot = '/Users/ryanfish/Code/zeeho-project';
  static const String lab = '$projectRoot/Gemini-Dummy';
  static const String rawImage = '$projectRoot/rawimage';
  static const String virtual = '$projectRoot/virtual';

  /// 自建 QEMU（`Gemini-Dummy/qemu-src/build/qemu-system-arm`）。
  static const String customQemu = '$lab/qemu-src/build/qemu-system-arm';

  /// 自建源码树，构建失败时提示用。
  static const String qemuSrc = '$lab/qemu-src';

  /// SPVD 虚拟硬盘的搜索顺序。可写 `AE5I_SPVD` 覆盖。
  static const List<String> spvdCandidates = [
    '$projectRoot/dist/qemu-ae5i/ae5i-software.spvd',
    '$lab/images/ae5i.spvd',
  ];

  /// 150Aura 裸 NAND dump（570,425,344 B = 131072 × 4352），SPVD 的原料。
  static const String nandDump150Aura =
      '$rawImage/春风150aura  XT26G04C(x1+ISP)@WSON8(8x6mm).BIN';

  static const String nandDumpAe5i =
      '$projectRoot/firmware/nand-backup/AE5.BIN';

  /// 从 SPVD 内 kernel 分区解出来的裸 ARM Image（每次启动按需重写）。
  static const String extractedKernel = '/tmp/ae5i-kernel-Image.bin';

  /// 开机动画：设备 anm_logo 分区里 logo.mkv 的预解码结果。
  ///
  /// 真机由 bootloader 的 PE 解码硬件播放（Linux 之前），模型没有 PE，
  /// 所以由 `tools/make_bootanim.py` 把原厂帧解出来交给模型重放。
  static const String bootAnim = '$projectRoot/dist/qemu-ae5i/anm_logo.bin';

  static String? resolveBootAnim() {
    final override = _envPath('AE5I_BOOT_ANIM');
    if (override != null) return File(override).existsSync() ? override : null;
    return File(bootAnim).existsSync() ? bootAnim : null;
  }

  static String? _envPath(String key) {
    final v = Platform.environment[key];
    return (v != null && v.isNotEmpty) ? v : null;
  }

  /// 返回自建 QEMU 路径；没有就返回 null（**不回落系统 QEMU**）。
  static String? resolveQemu() {
    final override = _envPath('AE5I_QEMU_BIN');
    if (override != null) return File(override).existsSync() ? override : null;
    return File(customQemu).existsSync() ? customQemu : null;
  }

  /// 返回可用的 SPVD；没有就返回 null。
  static String? resolveSpvd() {
    final override = _envPath('AE5I_SPVD');
    if (override != null) return File(override).existsSync() ? override : null;
    for (final p in spvdCandidates) {
      if (File(p).existsSync()) return p;
    }
    return null;
  }

  /// 生成 SPVD 的命令（UI 里直接给用户抄）。
  static String get spvdHint =>
      'python3 $lab/tools/nand2spvd.py "$nandDumpAe5i" $lab/images/ae5i.spvd';
}
