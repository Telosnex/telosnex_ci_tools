import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import '../actions/android-arm64-chroot/partition.dart';

/// A GPT disk with the partitions [parts] (first sector, last sector), and
/// [write] to fill in their contents.
File _disk(
  Directory dir,
  List<(int, int)> parts, {
  void Function(ByteData data)? write,
}) {
  const sectors = 4096;
  final data = ByteData(sectors * 512);
  final magic = 'EFI PART'.codeUnits;
  for (var i = 0; i < 8; i++) {
    data.setUint8(512 + i, magic[i]);
  }
  data.setUint64(512 + 72, 2, Endian.little); // entries at LBA 2
  data.setUint32(512 + 80, 128, Endian.little);
  data.setUint32(512 + 84, 128, Endian.little);
  for (final (i, (first, last)) in parts.indexed) {
    data.setUint64(1024 + i * 128 + 32, first, Endian.little);
    data.setUint64(1024 + i * 128 + 40, last, Endian.little);
  }
  write?.call(data);
  return File('${dir.path}/disk.img')
    ..writeAsBytesSync(data.buffer.asUint8List());
}

/// Writes liblp metadata at the super partition starting at [superStart]
/// (bytes): partitions [names], each with the extents in [extents]
/// (physical sector, sectors).
void _liblp(
  ByteData data,
  int superStart,
  List<String> names,
  List<List<(int, int)>> extents,
) {
  data.setUint32(superStart + 4096, 0x616C4467, Endian.little);
  final meta = superStart + 4096 + 2 * 4096;
  const headerSize = 128;
  data.setUint32(meta, 0x414C5030, Endian.little);
  data.setUint32(meta + 8, headerSize, Endian.little);
  final extentsAt = names.length * 52;
  final extentCount = extents.fold(0, (n, e) => n + e.length);
  data.setUint32(meta + 44, extentsAt + extentCount * 24, Endian.little);
  data.setUint32(meta + 80, 0, Endian.little);
  data.setUint32(meta + 84, names.length, Endian.little);
  data.setUint32(meta + 88, 52, Endian.little);
  data.setUint32(meta + 92, extentsAt, Endian.little);
  data.setUint32(meta + 96, extentCount, Endian.little);
  data.setUint32(meta + 100, 24, Endian.little);
  final tables = meta + headerSize;
  var next = 0;
  for (final (i, name) in names.indexed) {
    final entry = tables + i * 52;
    for (final (j, c) in name.codeUnits.indexed) {
      data.setUint8(entry + j, c);
    }
    data.setUint32(entry + 40, next, Endian.little);
    data.setUint32(entry + 44, extents[i].length, Endian.little);
    for (final (physical, sectors) in extents[i]) {
      final at = tables + extentsAt + next * 24;
      data.setUint64(at, sectors, Endian.little);
      data.setUint32(at + 8, 0, Endian.little);
      data.setUint64(at + 12, physical, Endian.little);
      next++;
    }
  }
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('partition'));
  tearDown(() => dir.deleteSync(recursive: true));

  List<(int, int)> find(File disk, String name) {
    final file = disk.openSync();
    try {
      return findPartition(file, name);
    } finally {
      file.closeSync();
    }
  }

  test('without dynamic partitions, the largest partition', () {
    final disk = _disk(dir, [(34, 99), (100, 3999)]);
    expect(find(disk, 'system'), [(100 * 512, 3900 * 512)]);
  });

  test('a partition of a super partition, by name', () {
    final disk = _disk(
      dir,
      [(34, 41), (64, 4095)],
      write: (data) => _liblp(
        data,
        64 * 512,
        ['product', 'system', 'vendor'],
        [
          [(2048, 100)],
          [(40, 200), (500, 8)],
          [(300, 50)],
        ],
      ),
    );
    expect(find(disk, 'system'), [
      (64 * 512 + 40 * 512, 200 * 512),
      (64 * 512 + 500 * 512, 8 * 512),
    ]);
    expect(find(disk, 'vendor'), [(64 * 512 + 300 * 512, 50 * 512)]);
    expect(
      () => find(disk, 'odm'),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          'no partition "odm" (has: product, system, vendor)',
        ),
      ),
    );
  });

  test('a file that is not a GPT disk', () {
    final file = File('${dir.path}/x')..writeAsBytesSync(List.filled(2048, 0));
    expect(() => find(file, 'system'), throwsFormatException);
  });
}
