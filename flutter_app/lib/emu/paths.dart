// 路径与可执行文件解析。
//
// 一条硬规则：**只用自建 QEMU**。系统 Homebrew 的 qemu-system-arm 没有
// sunplus-sp8368 机器模型，混用会得到 "unsupported machine type"，
// 所以这里找不到自建产物时返回 null，绝不回落到 /opt/homebrew。
//
// 不写死任何绝对路径：仓库根目录由「可执行文件位置 / 脚本位置 / 当前目录」
// 逐级向上探测得到（识别 qemu-src/ 与 tools/、flutter_app/），也可用环境变量
// 直接指定。目录改名、移动仓库、社区 clone 成任意名字都不会再出现「找不到 QEMU」。

import 'dart:io';

const String kMonSock = '/tmp/ae5i-mon.sock';
const String kFramePpm = '/tmp/ae5i-ui-frame.ppm';
const int kCfcpPort = 4502;

/// AE5I 仪表屏：1024×600（≈16:9，取自设备 runtime_cfg 的 UI_width/UI_height）。
const int kScreenW = 1024;
const int kScreenH = 600;

class LabPaths {
  LabPaths._();

  static String? _cachedLab;

  /// 仓库根目录（内含 qemu-src/、tools/、flutter_app/）。
  /// 探测不到时退回当前目录；此时 resolveQemu 会给出明确的缺失提示。
  static String get lab =>
      _cachedLab ??= _detectLab() ?? Directory.current.path;

  /// 工作区根目录（仓库上一级）；dist/rawimage/virtual 位于此。
  static String get projectRoot => Directory(lab).parent.path;

  static String get rawImage => '$projectRoot/rawimage';
  static String get virtual => '$projectRoot/virtual';

  /// 自建 QEMU（`lab`/qemu-src/build/qemu-system-arm）。
  static String get customQemu => '$lab/qemu-src/build/qemu-system-arm';

  /// 自建源码树，构建失败时提示用。
  static String get qemuSrc => '$lab/qemu-src';

  /// SPVD 虚拟硬盘的搜索顺序。可写 `AE5I_SPVD` 覆盖。
  static List<String> get spvdCandidates => [
    '$projectRoot/dist/qemu-ae5i/ae5i-software.spvd',
    '$lab/images/ae5i.spvd',
  ];

  /// 150Aura 裸 NAND dump（570,425,344 B = 131072 × 4352），SPVD 的原料。
  static String get nandDump150Aura =>
      '$rawImage/春风150aura  XT26G04C(x1+ISP)@WSON8(8x6mm).BIN';

  static String get nandDumpAe5i =>
      '$projectRoot/firmware/nand-backup/AE5.BIN';

  /// 从 SPVD 内 kernel 分区解出来的裸 ARM Image（每次启动按需重写）。
  static const String extractedKernel = '/tmp/ae5i-kernel-Image.bin';

  /// 开机动画：设备 anm_logo 分区里 logo.mkv 的预解码结果。
  ///
  /// 真机由 bootloader 的 PE 解码硬件播放（Linux 之前），模型没有 PE，
  /// 所以由 `tools/make_bootanim.py` 把原厂帧解出来交给模型重放。
  static String get bootAnim => '$projectRoot/dist/qemu-ae5i/anm_logo.bin';

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
    for (final dir in _labCandidates()) {
      final bin = '$dir/qemu-src/build/qemu-system-arm';
      if (File(bin).existsSync()) return bin;
    }
    return null;
  }

  /// 返回可用的 SPVD；没有就返回 null。
  static String? resolveSpvd() {
    final override = _envPath('AE5I_SPVD');
    if (override != null) return File(override).existsSync() ? override : null;
    // 保持原有优先级：工作区 dist 下已验收的 SPVD 优先，其次仓库 images/。
    for (final p in spvdCandidates) {
      if (File(p).existsSync()) return p;
    }
    for (final dir in _labCandidates()) {
      final p = '$dir/images/ae5i.spvd';
      if (File(p).existsSync()) return p;
    }
    return null;
  }

  /// 生成 SPVD 的命令（UI 里直接给用户抄）。
  static String get spvdHint =>
      'python3 $lab/tools/nand2spvd.py "$nandDumpAe5i" $lab/images/ae5i.spvd';

  // ------------------------------------------------------------ 路径探测

  /// 所有可能的仓库根目录，按优先级排列（去重）。
  static List<String> _labCandidates() {
    final roots = <String>[];
    void add(String p) {
      if (p.isEmpty) return;
      final norm = Directory(p).path;
      if (!roots.contains(norm)) roots.add(norm);
    }

    void addAncestors(String start) {
      var d = Directory(start);
      for (var i = 0; i < 12; i++) {
        add(d.path);
        final parent = d.parent.path;
        if (parent == d.path) break;
        d = Directory(parent);
      }
    }

    /// 允许把环境变量/当前目录指到「工作区根」，仓库是它的某个子目录。
    void addChildren(String p) {
      try {
        final d = Directory(p);
        if (!d.existsSync()) return;
        for (final e in d.listSync(followLinks: false)) {
          if (e is Directory) add(e.path);
        }
      } catch (_) {}
    }

    final envRoot = _envPath('AE5I_PROJECT_ROOT');
    if (envRoot != null) {
      addAncestors(envRoot);
      addChildren(envRoot);
    }
    addAncestors(File(Platform.resolvedExecutable).parent.path);
    try {
      addAncestors(File.fromUri(Platform.script).parent.path);
    } catch (_) {}
    addAncestors(Directory.current.path);
    addChildren(Directory.current.path);

    final labs = <String>[];
    for (final c in roots) {
      if (_isLab(c) && !labs.contains(c)) labs.add(c);
    }
    return labs;
  }

  static bool _isLab(String p) =>
      Directory('$p/qemu-src').existsSync() ||
      (Directory('$p/flutter_app').existsSync() &&
          Directory('$p/tools').existsSync());

  static String? _detectLab() {
    final labs = _labCandidates();
    // 优先选真正带构建产物的仓库，其次选带源码树的。
    for (final l in labs) {
      if (File('$l/qemu-src/build/qemu-system-arm').existsSync()) return l;
    }
    for (final l in labs) {
      if (_isLab(l)) return l;
    }
    return null;
  }
}
