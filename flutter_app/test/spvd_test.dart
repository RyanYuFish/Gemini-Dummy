// SPVD 解析与启动命令行构造的单元测试。
// 有真实 SPVD 时（/tmp/150aura.spvd 或 Gemini-Dummy/images/）会顺带校验几何/分区/CRC。

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ae5i_emu/main.dart';

void main() {
  group('SPVD 解析', () {
    final path = LabPaths.resolveSpvd();

    test('magic/几何/分区表与 NAND dump 一致', () {
      if (path == null) {
        // 没有 SPVD 时跳过（生成命令见 LabPaths.spvdHint）
        return;
      }
      final img = SpvdImage.open(path);
      expect(img, isNotNull, reason: 'SPVD 应可解析: $path');
      expect(img!.pageSize, 4096);
      expect(img.oobSize, 256);
      expect(img.pagesPerBlock, 64);
      expect(img.blockCount, 2048);
      expect(img.pageCount, 131072);
      expect(img.blockSize, 4096 * 64);
      expect(img.crcOk, isTrue, reason: '头部 CRC32 必须与写入端一致');
      expect(img.badBlocks, [383, 716, 1049, 1382, 1715]);
      // 真车 cmdlinepart 是 25 个分区（不是早先猜的 10 个）
      expect(img.partitions.length, 25);
      final mtdEntries = RegExp(r'0x([0-9a-fA-F]+)\(([^)]+)\)')
          .allMatches(MachineConst.defaultAppend)
          .map((m) => (m.group(2)!, int.parse(m.group(1)!, radix: 16)))
          .toList();
      expect(mtdEntries.length, img.partitions.length);
      var mtdOffset = 0;
      for (var i = 0; i < img.partitions.length; i++) {
        final part = img.partitions[i];
        expect(mtdEntries[i].$1, part.name, reason: 'MTD[$i] 名称与 SPVD 不同');
        expect(mtdOffset, part.offset, reason: '${part.name} 起始偏移与 SPVD 不同');
        expect(mtdEntries[i].$2, part.size, reason: '${part.name} 大小与 SPVD 不同');
        mtdOffset += mtdEntries[i].$2;
      }
      expect(mtdOffset, img.dataSize);
      final kernel = img.partition('kernel');
      expect(kernel, isNotNull);
      expect(kernel!.offset, 0x00800000);
      expect(kernel.size, 0x00480000);
      // 厂商原名带点，别“顺手”改成 rootfs
      expect(img.partition('rootfs.'), isNotNull);
      expect(img.partition('rootfs.')!.offset, 0x00C80000);
      final rtcfg = img.partition('runtime_cfg');
      expect(rtcfg, isNotNull);
      expect(rtcfg!.offset, 0x09280000);
      expect(rtcfg.size, 0x00100000);
      // 分区必须首尾相接、不重叠，最后一块到 512MiB
      for (var i = 1; i < img.partitions.length; i++) {
        expect(
          img.partitions[i].offset,
          img.partitions[i - 1].end,
          reason: '${img.partitions[i].name} 与上一分区不相接',
        );
      }
      expect(img.partitions.last.end, 0x20000000);
    });

    test('kernel 分区首部是 uImage，可抽出裸 Image', () {
      if (path == null) return;
      final img = SpvdImage.open(path)!;
      final head = img.read(0x00800000, 16);
      expect(head, isNotNull);
      // 大端 magic 0x27051956 == "27 05 19 56"
      expect(head!.sublist(0, 4), [0x27, 0x05, 0x19, 0x56]);

      final k = img.extractKernel('/tmp/ae5i-kernel-test.bin', force: true);
      expect(k, isNotNull);
      expect(k!.bytes, ByteData.sublistView(head).getUint32(12, Endian.big));
      expect(k.loadAddr, 0x00408000);
      final f = File(k.path);
      expect(f.existsSync(), isTrue);
      // 裸 ARM Image 首条指令是 ARM 分支，不是 uImage 魔数
      expect(f.readAsBytesSync().sublist(0, 4), [0x01, 0x90, 0x8f, 0xe2]);
    });

    test('非法文件返回 null 而不是抛异常', () {
      expect(SpvdImage.open('/tmp/definitely-not-here.spvd'), isNull);
      final tmp = File('/tmp/spvd_garbage.bin')
        ..writeAsBytesSync(List.filled(4096, 0));
      expect(SpvdImage.open(tmp.path), isNull);
    });

    test('crc32 与 zlib 已知值一致', () {
      final data = List<int>.generate(256, (i) => i);
      // python: zlib.crc32(bytes(range(256))) == 0x29058C73
      expect(crc32(Uint8List.fromList(data), 0, data.length), 0x29058C73);
    });
  });

  group('启动命令行', () {
    test('sunplus-sp8368 机器 + SPVD 环境变量，且不出现 virt', () {
      const spec = LaunchSpec(
        qemuBin: '/x/qemu-system-arm',
        kernel: '/tmp/k.img',
        spvd: '/tmp/d.spvd',
      );
      final argv = spec.argv();
      expect(argv[0], '-M');
      expect(argv[1], 'sunplus-sp8368');
      expect(argv, contains('-kernel'));
      expect(argv, contains('/tmp/k.img'));
      expect(argv, isNot(contains('virt')));
      expect(argv, isNot(contains('virtio-gpu-pci')));
      expect(spec.env()['SP_VDISK'], '/tmp/d.spvd');
      expect(spec.env()['SP_VDISK_BASE'], '0x50000000');
      expect(spec.shellLine(), contains('SP_VDISK=/tmp/d.spvd'));
      expect(spec.framebufferReady, isTrue);
      expect(spec.env()['SP_FB_FRAME'], kFramePpm);
      expect(argv, contains('chardev:cfcp'));
    });

    test('-append 与 U-Boot bootargs 一致（ttyS0 @ 921600）', () {
      const spec = LaunchSpec(qemuBin: 'q', kernel: 'k');
      final append = spec.argv()[spec.argv().indexOf('-append') + 1];
      expect(append, contains('console=ttyS0,921600'));
    });
  });
}
