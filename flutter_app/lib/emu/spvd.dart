// SPVD（Sunplus Virtual Disk）读取器 —— 纯 Dart，无 IO 副作用之外的依赖。
//
// 布局（小端，v1）：
//   0x000 "SPVD" | 0x004 version | 0x008 page_size | 0x00C oob_size
//   0x010 pages_per_block | 0x014 block_count | 0x018 page_count
//   0x01C data_offset(0x1000) | 0x020 u64 data_size
//   0x028 bad_count | 0x02C part_count | 0x030 flags | 0x034 header_crc32
//   0x100 u32 bad_blocks[]        （块号）
//   0x400 44B/项 分区：name[32] + u32 addr + u32 size + u32 rsvd
//   0x1000 起：扁平页数据（已剔除 OOB），逻辑页 N 在 N*page_size
//
// 也就是说：**客机/虚拟化平台按页线性读即可**，不必关心物理坏块稀疏布局。

import 'dart:io';
import 'dart:typed_data';

const int kSpvdHeaderSize = 0x1000;
const int kSpvdBadOff = 0x100;
const int kSpvdPartOff = 0x400;
const int kSpvdPartNameLen = 32;
const int kSpvdPartEntry = 44; // 32 + 4 + 4 + 4
const int kSpvdMagic = 0x44565053; // 字节 "SPVD"（53 50 56 44）按小端读

class SpvdPartition {
  final String name;
  final int offset; // 扁平地址（不含 OOB），与 `sunplus-vdisk` 线性窗口一致
  final int size;
  const SpvdPartition(this.name, this.offset, this.size);

  int get end => offset + size;

  String get sizeText {
    const mb = 1024 * 1024;
    if (size >= mb) {
      final v = size / mb;
      return v == v.roundToDouble()
          ? '${v.toStringAsFixed(0)} MB'
          : '${v.toStringAsFixed(1)} MB';
    }
    return '${(size / 1024).toStringAsFixed(0)} KB';
  }
}

class SpvdImage {
  final String path;
  final int version;
  final int pageSize;
  final int oobSize;
  final int pagesPerBlock;
  final int blockCount;
  final int pageCount;
  final int dataOffset;
  final int dataSize;
  final int flags;
  final bool crcOk;
  final List<int> badBlocks;
  final List<SpvdPartition> partitions;
  final int fileSize;

  const SpvdImage({
    required this.path,
    required this.version,
    required this.pageSize,
    required this.oobSize,
    required this.pagesPerBlock,
    required this.blockCount,
    required this.pageCount,
    required this.dataOffset,
    required this.dataSize,
    required this.flags,
    required this.crcOk,
    required this.badBlocks,
    required this.partitions,
    required this.fileSize,
  });

  int get blockSize => pageSize * pagesPerBlock;

  /// 头部 + 数据区应有的总字节数。
  int get expectedBytes => dataOffset + dataSize;

  /// 数据区是否被截断（dump 不完整时能一眼看出来）。
  bool get truncated => fileSize < expectedBytes;

  String get geometryText =>
      'page $pageSize + oob $oobSize × $pagesPerBlock 页/块 · $blockCount 块';

  String get sizeText {
    final gb = dataSize / (1024 * 1024 * 1024);
    if (gb >= 1) return '${gb.toStringAsFixed(2)} GB';
    return '${(dataSize / (1024 * 1024)).toStringAsFixed(0)} MB';
  }

  SpvdPartition? partition(String name) {
    for (final p in partitions) {
      if (p.name == name) return p;
    }
    return null;
  }

  static SpvdImage? open(String path) {
    RandomAccessFile? f;
    try {
      final file = File(path);
      if (!file.existsSync()) return null;
      f = file.openSync();
      final fileSize = f.lengthSync();
      final hdr = Uint8List(kSpvdHeaderSize);
      final n = f.readIntoSync(hdr);
      if (n < 0x38) return null;

      final bd = ByteData.sublistView(hdr);
      if (bd.getUint32(0x00, Endian.little) != kSpvdMagic) return null;

      final pageSize = bd.getUint32(0x08, Endian.little);
      final oobSize = bd.getUint32(0x0C, Endian.little);
      final ppb = bd.getUint32(0x10, Endian.little);
      final blocks = bd.getUint32(0x14, Endian.little);
      if (pageSize == 0 || ppb == 0 || blocks == 0) return null;

      final badCount = bd.getUint32(0x28, Endian.little);
      final partCount = bd.getUint32(0x2C, Endian.little);

      final bad = <int>[];
      for (var i = 0; i < badCount; i++) {
        final off = kSpvdBadOff + i * 4;
        if (off + 4 > hdr.length) break;
        bad.add(bd.getUint32(off, Endian.little));
      }

      final parts = <SpvdPartition>[];
      for (var i = 0; i < partCount; i++) {
        final base = kSpvdPartOff + i * kSpvdPartEntry;
        if (base + kSpvdPartEntry > hdr.length) break;
        final nameBytes = hdr.sublist(base, base + kSpvdPartNameLen);
        final zero = nameBytes.indexOf(0);
        final name = String.fromCharCodes(
          zero < 0 ? nameBytes : nameBytes.sublist(0, zero),
        );
        final addr = bd.getUint32(base + kSpvdPartNameLen, Endian.little);
        final size = bd.getUint32(base + kSpvdPartNameLen + 4, Endian.little);
        if (name.isEmpty) continue;
        parts.add(SpvdPartition(name, addr, size));
      }

      final crcStored = bd.getUint32(0x34, Endian.little);
      final crcCalc = crc32(hdr, 0, 0x34);

      return SpvdImage(
        path: path,
        version: bd.getUint32(0x04, Endian.little),
        pageSize: pageSize,
        oobSize: oobSize,
        pagesPerBlock: ppb,
        blockCount: blocks,
        pageCount: bd.getUint32(0x18, Endian.little),
        dataOffset: bd.getUint32(0x1C, Endian.little),
        dataSize: bd.getUint64(0x20, Endian.little),
        flags: bd.getUint32(0x30, Endian.little),
        crcOk: crcCalc == crcStored,
        badBlocks: bad,
        partitions: parts,
        fileSize: fileSize,
      );
    } catch (_) {
      return null;
    } finally {
      try {
        f?.closeSync();
      } catch (_) {}
    }
  }

  /// 按扁平地址读取原始字节。
  Uint8List? read(int offset, int length) {
    RandomAccessFile? f;
    try {
      f = File(path).openSync();
      if (offset < 0 || offset + length > dataSize) return null;
      f.setPositionSync(dataOffset + offset);
      final buf = Uint8List(length);
      final n = f.readIntoSync(buf);
      if (n != length) return null;
      return buf;
    } catch (_) {
      return null;
    } finally {
      try {
        f?.closeSync();
      } catch (_) {}
    }
  }

  /// 从 `kernel` 分区取出裸 ARM Image（uImage 头 64 B 之后的部分）。
  ///
  /// 这样整条启动链只有一个输入：**NAND 数据本身**。内核不再需要外部文件。
  KernelImage? extractKernel(String outPath, {bool force = false}) {
    final part = partition('kernel');
    if (part == null) return null;
    final head = read(part.offset, 0x40);
    if (head == null) return null;
    final bd = ByteData.sublistView(head);
    if (bd.getUint32(0, Endian.big) != 0x27051956) {
      // 不是 uImage：当作裸 Image 直接用（不同批次固件可能如此）
      return _dump(
        part.offset,
        part.size,
        outPath,
        loadAddr: 0,
        name: '',
        force: force,
      );
    }
    final payload = bd.getUint32(12, Endian.big);
    final load = bd.getUint32(16, Endian.big);
    final name = String.fromCharCodes(
      head.sublist(32, 64),
    ).replaceAll(RegExp(r'\x00+$'), '');
    if (payload == 0 || payload > part.size) return null;
    return _dump(
      part.offset + 0x40,
      payload,
      outPath,
      loadAddr: load,
      name: name,
      force: force,
    );
  }

  KernelImage? _dump(
    int offset,
    int length,
    String outPath, {
    required int loadAddr,
    required String name,
    required bool force,
  }) {
    final out = File(outPath);
    if (!force && out.existsSync() && out.lengthSync() == length) {
      return KernelImage(outPath, length, loadAddr, name, cached: true);
    }
    final bytes = read(offset, length);
    if (bytes == null) return null;
    out.writeAsBytesSync(bytes, flush: true);
    return KernelImage(outPath, length, loadAddr, name, cached: false);
  }
}

class KernelImage {
  final String path;
  final int bytes;
  final int loadAddr;
  final String name;
  final bool cached;
  const KernelImage(
    this.path,
    this.bytes,
    this.loadAddr,
    this.name, {
    this.cached = false,
  });

  String get label {
    final n = name.isEmpty ? 'ARM Image' : name;
    final addr = loadAddr == 0 ? '' : ' @0x${loadAddr.toRadixString(16)}';
    return '$n$addr · ${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }
}

// ---------------------------------------------------------------- crc32

final Uint32List _crcTable = _buildCrcTable();

Uint32List _buildCrcTable() {
  final t = Uint32List(256);
  for (var i = 0; i < 256; i++) {
    var c = i;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1);
    }
    t[i] = c;
  }
  return t;
}

/// 标准 CRC-32（IEEE 802.3），与 Python `zlib.crc32` 一致。
int crc32(Uint8List data, int start, int end) {
  var c = 0xFFFFFFFF;
  for (var i = start; i < end; i++) {
    c = _crcTable[(c ^ data[i]) & 0xFF] ^ (c >> 8);
  }
  return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}
