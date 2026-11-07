// Prints where a partition of an Android system image is: one line per
// extent, `<byte offset in the file> <byte length>`.
//
// usage: dart partition.dart <system.img> <partition>
//
// The image is a GPT disk. Its largest partition is either the file system
// itself (Android 9 and older, one partition) or a "super" partition with
// dynamic partitions (liblp format), where <partition> is looked up.
import 'dart:io';
import 'dart:typed_data';

void main(List<String> args) {
  if (args.length != 2) {
    stderr.writeln('usage: dart partition.dart <system.img> <partition>');
    exit(64);
  }
  final file = File(args[0]).openSync();
  try {
    for (final (offset, length) in findPartition(file, args[1])) {
      stdout.writeln('$offset $length');
    }
  } on FormatException catch (e) {
    stderr.writeln('${args[0]}: ${e.message}');
    exit(1);
  } finally {
    file.closeSync();
  }
}

const _sector = 512;
const _gptMagic = 'EFI PART';
const _geometryMagic = 0x616C4467;
const _metadataMagic = 0x414C5030;

// liblp: the 4 KiB before the geometry are reserved, and two copies of the
// 4 KiB geometry come before the metadata slots.
const _reserved = 4096;
const _geometrySize = 4096;

/// The extents of [name]: (byte offset in [file], byte length).
List<(int, int)> findPartition(RandomAccessFile file, String name) {
  final (start, length) = _largestGptPartition(file);
  final geometry = _read(file, start + _reserved, 52);
  if (geometry.getUint32(0, Endian.little) != _geometryMagic) {
    // No dynamic partitions: the partition is the file system.
    return [(start, length)];
  }
  final metadataStart = start + _reserved + 2 * _geometrySize;
  final header = _read(file, metadataStart, 128);
  if (header.getUint32(0, Endian.little) != _metadataMagic) {
    throw const FormatException('no liblp metadata after the geometry');
  }
  final headerSize = header.getUint32(8, Endian.little);
  final tablesSize = header.getUint32(44, Endian.little);
  final tables = _read(file, metadataStart + headerSize, tablesSize);
  // Table descriptors: offset (in the tables), number of entries, entry size.
  (int, int, int) descriptor(int at) => (
    header.getUint32(at, Endian.little),
    header.getUint32(at + 4, Endian.little),
    header.getUint32(at + 8, Endian.little),
  );
  final (partitionsAt, partitionCount, partitionSize) = descriptor(80);
  final (extentsAt, _, extentSize) = descriptor(92);
  final names = <String>[];
  for (var i = 0; i < partitionCount; i++) {
    final entry = partitionsAt + i * partitionSize;
    final entryName = String.fromCharCodes(
      tables.buffer
          .asUint8List(tables.offsetInBytes + entry, 36)
          .takeWhile((c) => c != 0),
    );
    names.add(entryName);
    if (entryName != name) continue;
    final first = tables.getUint32(entry + 40, Endian.little);
    final count = tables.getUint32(entry + 44, Endian.little);
    return [
      for (var e = first; e < first + count; e++)
        _extent(tables, extentsAt + e * extentSize, start),
    ];
  }
  throw FormatException('no partition "$name" (has: ${names.join(', ')})');
}

(int, int) _extent(ByteData tables, int at, int superStart) {
  final sectors = tables.getUint64(at, Endian.little);
  final kind = tables.getUint32(at + 8, Endian.little);
  if (kind != 0) throw FormatException('extent of type $kind, not linear');
  final physical = tables.getUint64(at + 12, Endian.little);
  return (superStart + physical * _sector, sectors * _sector);
}

/// The largest partition of the GPT disk in [file]: (byte offset, length).
(int, int) _largestGptPartition(RandomAccessFile file) {
  final header = _read(file, _sector, 92);
  final magic = String.fromCharCodes(header.buffer.asUint8List(0, 8));
  if (magic != _gptMagic) throw const FormatException('not a GPT disk');
  final entriesLba = header.getUint64(72, Endian.little);
  final count = header.getUint32(80, Endian.little);
  final size = header.getUint32(84, Endian.little);
  final entries = _read(file, entriesLba * _sector, count * size);
  var best = (0, 0);
  for (var i = 0; i < count; i++) {
    final first = entries.getUint64(i * size + 32, Endian.little);
    final last = entries.getUint64(i * size + 40, Endian.little);
    if (first == 0 && last == 0) continue;
    final length = (last - first + 1) * _sector;
    if (length > best.$2) best = (first * _sector, length);
  }
  if (best.$2 == 0) throw const FormatException('the GPT has no partition');
  return best;
}

ByteData _read(RandomAccessFile file, int offset, int length) {
  file.setPositionSync(offset);
  final bytes = file.readSync(length);
  if (bytes.length != length) {
    throw FormatException('the file ends before byte ${offset + length}');
  }
  return ByteData.sublistView(bytes);
}
