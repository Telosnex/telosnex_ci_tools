// Checks that an APK's 64-bit native libraries load on Android devices with
// 16 KB memory pages (Google Play requires it from Android 15 targets on):
// each LOAD segment of each lib/arm64-v8a and lib/x86_64 .so is aligned to
// 16 KB or more, and each such .so stored uncompressed starts at a 16 KB
// offset in the APK, so that Android can map it from the APK.
//
// usage: dart page_alignment.dart <app.apk>...
//
// Prints one line per problem and exits 1 if there are any.
import 'dart:io';
import 'dart:typed_data';

const pageSize = 16384;

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage: dart page_alignment.dart <app.apk>...');
    exit(64);
  }
  var problems = 0;
  for (final path in args) {
    final List<String> found;
    try {
      found = checkApk(File(path).readAsBytesSync());
    } on FormatException catch (e) {
      stdout.writeln('$path: ${e.message}');
      problems++;
      continue;
    }
    for (final problem in found) {
      stdout.writeln('$path: $problem');
    }
    problems += found.length;
  }
  if (problems > 0) exit(1);
}

/// The 16 KB page problems of the APK [bytes], one sentence each.
List<String> checkApk(Uint8List bytes) {
  final problems = <String>[];
  for (final entry in zipEntries(bytes)) {
    final name = entry.name;
    if (!name.endsWith('.so')) continue;
    if (!name.startsWith('lib/arm64-v8a/') && !name.startsWith('lib/x86_64/')) {
      continue;
    }
    if (entry.method == 0 && entry.dataOffset % pageSize != 0) {
      problems.add(
        '$name is stored at offset ${entry.dataOffset}, not a multiple of '
        '16 KB (zipalign -P 16, or AGP 8.5.1 or newer).',
      );
    }
    final Uint8List elf;
    try {
      elf = entry.data(bytes);
    } on FormatException catch (e) {
      problems.add('$name: ${e.message}');
      continue;
    }
    for (final align in loadAlignments(elf, name)) {
      if (align < pageSize) {
        problems.add(
          '$name has a LOAD segment aligned to $align bytes, not 16 KB '
          '(link with -Wl,-z,max-page-size=16384, or NDK r28 or newer).',
        );
        break;
      }
    }
  }
  return problems;
}

/// One file of a zip archive.
final class ZipEntry {
  ZipEntry(this.name, this.method, this.dataOffset, this.compressedSize);

  final String name;

  /// 0: stored, 8: deflated.
  final int method;

  /// Where the file's data starts in the archive.
  final int dataOffset;
  final int compressedSize;

  /// The file's contents, from the archive [bytes].
  Uint8List data(Uint8List bytes) {
    if (dataOffset + compressedSize > bytes.length) {
      throw const FormatException('the file runs past the end of the APK');
    }
    final raw = Uint8List.sublistView(
      bytes,
      dataOffset,
      dataOffset + compressedSize,
    );
    switch (method) {
      case 0:
        return raw;
      case 8:
        return Uint8List.fromList(ZLibDecoder(raw: true).convert(raw));
      default:
        throw FormatException('compression method $method is not supported');
    }
  }
}

/// The files of the zip archive [bytes], from its central directory.
List<ZipEntry> zipEntries(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  // The end of central directory record: 22 bytes and a comment of at most
  // 65535 bytes.
  var end = -1;
  for (
    var i = bytes.length - 22;
    i >= 0 && i >= bytes.length - 22 - 65535;
    i--
  ) {
    if (data.getUint32(i, Endian.little) == 0x06054b50) {
      end = i;
      break;
    }
  }
  if (end < 0) throw const FormatException('not a zip file');
  final count = data.getUint16(end + 10, Endian.little);
  var at = data.getUint32(end + 16, Endian.little);
  final entries = <ZipEntry>[];
  for (var i = 0; i < count; i++) {
    if (at + 46 > bytes.length ||
        data.getUint32(at, Endian.little) != 0x02014b50) {
      throw const FormatException('the zip central directory is damaged');
    }
    final method = data.getUint16(at + 10, Endian.little);
    final compressedSize = data.getUint32(at + 20, Endian.little);
    final nameLength = data.getUint16(at + 28, Endian.little);
    final extraLength = data.getUint16(at + 30, Endian.little);
    final commentLength = data.getUint16(at + 32, Endian.little);
    final local = data.getUint32(at + 42, Endian.little);
    final name = String.fromCharCodes(bytes, at + 46, at + 46 + nameLength);
    if (local + 30 > bytes.length ||
        data.getUint32(local, Endian.little) != 0x04034b50) {
      throw FormatException('the zip header of $name is damaged');
    }
    // The local header has its own name and extra field lengths: zipalign
    // pads the extra field there.
    final dataOffset =
        local +
        30 +
        data.getUint16(local + 26, Endian.little) +
        data.getUint16(local + 28, Endian.little);
    entries.add(ZipEntry(name, method, dataOffset, compressedSize));
    at += 46 + nameLength + extraLength + commentLength;
  }
  return entries;
}

/// The p_align of each LOAD segment of the 64-bit little-endian ELF file
/// [elf], named [name] in errors.
List<int> loadAlignments(Uint8List elf, String name) {
  if (elf.length < 64 ||
      elf[0] != 0x7f ||
      elf[1] != 0x45 ||
      elf[2] != 0x4c ||
      elf[3] != 0x46) {
    throw FormatException('$name is not an ELF file');
  }
  if (elf[4] != 2 || elf[5] != 1) {
    throw FormatException('$name is not a 64-bit little-endian ELF file');
  }
  final data = ByteData.sublistView(elf);
  final phoff = data.getUint64(32, Endian.little);
  final phentsize = data.getUint16(54, Endian.little);
  final phnum = data.getUint16(56, Endian.little);
  if (phentsize < 56 || phoff + phnum * phentsize > elf.length) {
    throw FormatException('$name has a damaged program header table');
  }
  return [
    for (var i = 0; i < phnum; i++)
      if (data.getUint32(phoff + i * phentsize, Endian.little) == 1) // PT_LOAD
        data.getUint64(phoff + i * phentsize + 48, Endian.little),
  ];
}
