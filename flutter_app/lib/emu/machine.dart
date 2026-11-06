// 虚拟化后端的启动规格：机器模型 + 命令行 + 环境变量。
//
// 机器模型 `sunplus-sp8368` 只在**自建 QEMU** 里存在（vendored 于 Gemini-Dummy/qemu-src），
// 所以这里不接受系统 QEMU。
//
// 参数面（由 hw/arm/sunplus-sp8368.c 提供）：
//   -M sunplus-sp8368                       Cortex-A7 / 256MB / GIC-400 / 27MHz timer
//   -kernel <裸 ARM Image>                  加载到 0x408000（loader_start 已下移）
//   -append console=ttyS0,921600            与 U-Boot bootargs 一致
//   SP_VDISK=<path.spvd>                    sunplus-vdisk：NAND 扁平线性窗 + 分区寄存器
//   SP_VDISK_BASE=0x..                      线性窗基址（默认 0x50000000）
//   SP_FW_FILE / SP_FW_TRACE                板级 config 注入（M2 兜底手段）
//   SP_PSU_TRACE=1                          时钟/PINMUX 寄存器访问追踪

import 'dart:io';

import 'paths.dart';
import 'spvd.dart';

/// 机器常量（与 C 侧 `SP_*` 宏对应）。
class MachineConst {
  MachineConst._();
  static const String id = 'sunplus-sp8368';
  static const String desc = 'Sunplus SP8368/GEMINI dashboard (AE5i / 150Aura)';
  static const int ramMb = 256;
  static const int kernelLink = 0xC0408000;
  static const int vdiskDataBase = 0x50000000;
  static const int vdiskRegsBase = 0x40000000;
  static const String defaultAppend =
      'console=ttyS0,921600 loglevel=7 panic=1 '
      'mtdparts=sp_spinand.0:0x40000(nand_header),0x40000(xboot1),'
      '0xc0000(uboot1),0x1c0000(uboot2),0x80000(env),0x80000(env_redund),'
      '0x400000(ecos),0x480000(kernel),0x480000(rootfs.),0x80000(opt.),'
      '0x3000000(spsdk.),0x4040000(spapp.),0x1000000(nvm),0x40000(pq),'
      '0x40000(tcon),0x40000(iop_car),0x100000(runtime_cfg),0x40000(vi),'
      '0x980000(isp_logo),0x40000(vendordata),0xbc0000(pat_logo),'
      '0x40000(version_info),0x40000(vd_restore),0x100000(anm_logo),'
      '0x15540000(userdata) res_chunkmem=0x04000000@0x0C000000 '
      // 1024x600 × 32bpp × 双缓冲 = 4.69 MiB，三层各留 6 MiB（与模型
      // SP_FB_BASE/SP_FB_STEP 及 IPC cmd 3 的 fb 地址必须一致）。
      'res_fb0=0x00600000@0x0C000000 res_fb1=0x00600000@0x0C600000 '
      'res_fb2=0x00600000@0x0CC00000';
}

class LaunchSpec {
  final String qemuBin;
  final String kernel;
  final String? spvd;
  final String append;
  final String monitorSock;
  final String serialTarget;
  final int cfcpPort;
  final String framePath;

  final bool paused;

  /// 开机动画 blob（`tools/make_bootanim.py` 产物）；null 表示不播。
  final String? bootAnim;

  /// 唤醒触发文件：存在即让模型重放开机动画（对应真车「解锁后仪表点亮」）。
  /// 由客户端在解锁时创建。null 表示上电即播（兼容无门控场景）。
  final String? wakeFile;

  /// 关机动画触发文件：存在即让模型倒放 logo（logo out）。由客户端在下电前创建，
  /// 给模型约 2 秒播放，随后 guest 的 poweroff 才让面板变黑。
  final String? shutdownWakeFile;

  /// 额外环境变量（除 SP_VDISK 外）。
  final Map<String, String> extraEnv;

  const LaunchSpec({
    required this.qemuBin,
    required this.kernel,
    this.spvd,
    this.append = MachineConst.defaultAppend,
    this.monitorSock = kMonSock,
    this.serialTarget = 'stdio',
    this.cfcpPort = kCfcpPort,
    this.framePath = kFramePpm,
    this.paused = false,
    this.bootAnim,
    this.wakeFile,
    this.shutdownWakeFile,
    this.extraEnv = const {},
  });

  Map<String, String> env() {
    final m = <String, String>{
      'SP_IPC_STUB': '1',
      // 不要在这里设 SP_PC_MS：它会**覆盖**模型侧 SP_FB_PUBLISH_MS，
      // 把整帧发布节拍钉死（旧值 500 → 2 fps，动画看起来就是不播）。
      // 发布节拍由模型 SP_FB_PUBLISH_MS 决定；pc 采样频率不影响画面。
      // 三个显示层（OSD0/1/2）全部注册：只给一层时原厂 PlatformControl 会打
      // "Framebuffer of Background not create"，背景层与主题底图随之缺失。
      'SP_FB_MULTI': '1',
      // 按 PFC 的层序把背景层（窗口 1）合成到 OSD 之下：背景全黑时逐字节等价。
      'SP_FB_COMPOSITE': '1',
    };
    // 帧通道：模型写 PPM，客户端解析。
    //
    // 试过「模型直出原始 BGRA + .meta、客户端零转换」，实测**没有收益**：
    // 两种通道的帧间隔模式完全一致（40/80 ms 交替），上限由模型发布节拍 ×
    // 客户机 TCG 速度决定，客户端解码从来不是瓶颈（PPM 已能跑满 15.5 fps）。
    // 该路径在开机动画窗口内还会确定性地提前断流，故不采用。
    m['SP_FB_FRAME'] = framePath;
    if (bootAnim != null) {
      // 真机这段动画是 bootloader 的 PE 硬件放的，模型用原厂帧重放。
      m['SP_BOOT_ANIM'] = bootAnim!;
      // 真车：仪表在解锁（车辆启动）后才点亮，解锁瞬间重放 logo 开机动画。
      // 设 wakeFile 后模型不在上电时播，而是等该文件出现（客户端解锁时创建）。
      if (wakeFile != null) {
        m['SP_WAKE_FILE'] = wakeFile!;
      }
      // 关机动画复用开机动画资源，倒放；下电前由客户端创建触发文件。
      if (shutdownWakeFile != null) {
        m['SP_SHUTDOWN_WAKE_FILE'] = shutdownWakeFile!;
      }
    }
    if (spvd != null) {
      m['SP_VDISK'] = spvd!;
      m['SP_VDISK_BASE'] = '0x${MachineConst.vdiskDataBase.toRadixString(16)}';
    }
    m.addAll(extraEnv);
    // 诊断透传：AE5I_EXTRA_ENV="SP_FB_REG=1;SP_FB_FORCE_REDRAW=1" 直接追加到
    // 模型环境。探针/取证用，正常启动不设这个变量。
    final diag = Platform.environment['AE5I_EXTRA_ENV'];
    if (diag != null && diag.isNotEmpty) {
      for (final kv in diag.split(';')) {
        final i = kv.indexOf('=');
        if (i > 0) {
          m[kv.substring(0, i).trim()] = kv.substring(i + 1).trim();
        }
      }
    }
    return m;
  }

  List<String> argv() => [
    '-M',
    MachineConst.id,
    '-m',
    '${MachineConst.ramMb}',
    '-kernel',
    kernel,
    '-append',
    append,
    '-serial',
    serialTarget,
    '-chardev',
    'socket,id=cfcp,host=127.0.0.1,port=$cfcpPort,server=on,wait=off',
    '-serial',
    'chardev:cfcp',
    '-monitor',
    'unix:$monitorSock,server,nowait',
    '-display',
    'none',
    '-no-reboot',
    if (paused) '-S',
  ];

  /// 供 UI 展示的完整命令行（含环境变量前缀）。
  String shellLine() {
    final e = env().entries.map((x) => '${x.key}=${x.value}');
    return ['env', ...e, qemuBin, ...argv()]
        .map(
          (a) => RegExp(r'^[a-zA-Z0-9_./:=,@+\-]+$').hasMatch(a)
              ? a
              : "'${a.replaceAll("'", "'\\''")}'",
        )
        .join(' ');
  }

  /// The model publishes snapshots of the guest framebuffer to kFramePpm.
  bool get framebufferReady => true;
}

enum BootStage { resolveQemu, resolveSpvd, parseSpvd, extractKernel, ready }

class BootPreparation {
  final List<String> steps;
  final String? error;
  final LaunchSpec? spec;
  final SpvdImage? spvd;
  final KernelImage? kernel;

  const BootPreparation({
    required this.steps,
    this.error,
    this.spec,
    this.spvd,
    this.kernel,
  });

  bool get ok => spec != null && error == null;

  /// 逐项准备启动物：自建 QEMU → SPVD → 解析头部 → 抽内核 → 命令行。
  ///
  /// [kernelPath] 传入时跳过 SPVD 抽内核（调试单个 Image 用）。
  static BootPreparation prepare({
    String? spvdPath,
    String? kernelPath,
    String kernelOutputPath = LabPaths.extractedKernel,
  }) {
    final steps = <String>[];

    final qemu = LabPaths.resolveQemu();
    if (qemu == null) {
      return BootPreparation(steps: steps, error: _qemuMissing());
    }
    steps.add('自建 QEMU: $qemu');

    if (kernelPath != null) {
      final kf = File(kernelPath);
      if (!kf.existsSync()) {
        return BootPreparation(steps: steps, error: '内核文件不存在：$kernelPath');
      }
      steps.add(
        '内核（指定文件）: $kernelPath '
        '(${(kf.lengthSync() / (1024 * 1024)).toStringAsFixed(2)} MB)',
      );
      return BootPreparation(
        steps: steps,
        spec: LaunchSpec(
          qemuBin: qemu,
          kernel: kernelPath,
          spvd: spvdPath ?? LabPaths.resolveSpvd(),
          bootAnim: LabPaths.resolveBootAnim(),
        ),
        kernel: KernelImage(kernelPath, kf.lengthSync(), 0, '', cached: true),
      );
    }

    final spvdPathResolved = spvdPath ?? LabPaths.resolveSpvd();
    if (spvdPathResolved == null) {
      return BootPreparation(steps: steps, error: _spvdMissing());
    }
    steps.add('SPVD: $spvdPathResolved');
    // 开机动画是可选件：缺失时模型照常启动，只是没有原厂 logo 那一段。
    final anim = LabPaths.resolveBootAnim();
    steps.add(
      anim == null
          ? '开机动画: 未生成（python3 ${LabPaths.lab}/tools/make_bootanim.py）'
          : '开机动画: $anim',
    );

    final img = SpvdImage.open(spvdPathResolved);
    if (img == null) {
      return BootPreparation(
        steps: steps,
        error: '不是有效的 SPVD（magic 不符）：$spvdPathResolved',
      );
    }
    steps.add(
      '几何: ${img.geometryText} · 坏块 ${img.badBlocks.length} · '
      '分区 ${img.partitions.length} · CRC ${img.crcOk ? "ok" : "BAD"}',
    );
    if (!img.crcOk || img.truncated || img.version != 1) {
      return BootPreparation(
        steps: steps,
        spvd: img,
        error:
            'SPVD 校验失败（版本=${img.version}，CRC=${img.crcOk}，截断=${img.truncated}）',
      );
    }

    // The cache path was previously shared by other board images; matching
    // length alone is insufficient to identify the original AE5I kernel.
    final kernel = img.extractKernel(kernelOutputPath, force: true);
    if (kernel == null) {
      return BootPreparation(steps: steps, error: 'SPVD 内 kernel 分区缺失或不可解析');
    }
    steps.add(
      '内核: ${kernel.label} → ${kernel.path}'
      '${kernel.cached ? '（复用缓存）' : '（已从 NAND 抽出）'}',
    );

    return BootPreparation(
      steps: steps,
      spec: LaunchSpec(
        qemuBin: qemu,
        kernel: kernel.path,
        spvd: spvdPathResolved,
        bootAnim: LabPaths.resolveBootAnim(),
      ),
      spvd: img,
      kernel: kernel,
    );
  }

  static String _qemuMissing() =>
      '未找到自建 QEMU（系统 QEMU 无 sunplus-sp8368 机器模型，不回落）。\n'
      '构建：python3 ${LabPaths.lab}/tools/build_model.py\n'
      '产物：${LabPaths.customQemu}\n'
      '仓库位置不同可指定 AE5I_PROJECT_ROOT 或 AE5I_QEMU_BIN';

  static String _spvdMissing() =>
      '未找到 SPVD 虚拟硬盘。先用 NAND dump 生成一个：\n${LabPaths.spvdHint}\n'
      '或设置 AE5I_SPVD=/path/to/xxx.spvd';
}
