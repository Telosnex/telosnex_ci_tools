import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import '../actions/android-test-apks/page_alignment.dart';

/// A 64-bit little-endian ELF file with LOAD segments of the alignments
/// [aligns], and a PT_DYNAMIC segment aligned to 8.
Uint8List _elf(List<int> aligns) {
  final phnum = aligns.length + 1;
  final data = ByteData(64 + phnum * 56);
  data
    ..setUint32(0, 0x464c457f, Endian.little)
    ..setUint8(4, 2)
    ..setUint8(5, 1)
    ..setUint64(32, 64, Endian.little)
    ..setUint16(54, 56, Endian.little)
    ..setUint16(56, phnum, Endian.little);
  for (final (i, align) in aligns.indexed) {
    data
      ..setUint32(64 + i * 56, 1, Endian.little)
      ..setUint64(64 + i * 56 + 48, align, Endian.little);
  }
  data
    ..setUint32(64 + aligns.length * 56, 2, Endian.little)
    ..setUint64(64 + aligns.length * 56 + 48, 8, Endian.little);
  return data.buffer.asUint8List();
}

/// A zip archive of [files] (name, contents, deflated), each stored file's
/// data padded to start at a multiple of [storedAlign] plus [shift].
Uint8List _zip(
  List<(String, Uint8List, bool)> files, {
  int storedAlign = 1,
  int shift = 0,
}) {
  final out = BytesBuilder();
  final central = BytesBuilder();
  for (final (name, contents, deflate) in files) {
    final data = deflate
        ? Uint8List.fromList(ZLibEncoder(raw: true).convert(contents))
        : contents;
    final local = out.length;
    var extra = 0;
    if (!deflate) {
      final start = local + 30 + name.length;
      extra = (storedAlign - start % storedAlign) % storedAlign + shift;
    }
    final header = ByteData(30)
      ..setUint32(0, 0x04034b50, Endian.little)
      ..setUint16(8, deflate ? 8 : 0, Endian.little)
      ..setUint32(18, data.length, Endian.little)
      ..setUint32(22, contents.length, Endian.little)
      ..setUint16(26, name.length, Endian.little)
      ..setUint16(28, extra, Endian.little);
    out
      ..add(header.buffer.asUint8List())
      ..add(name.codeUnits)
      ..add(Uint8List(extra))
      ..add(data);
    final entry = ByteData(46)
      ..setUint32(0, 0x02014b50, Endian.little)
      ..setUint16(10, deflate ? 8 : 0, Endian.little)
      ..setUint32(20, data.length, Endian.little)
      ..setUint32(24, contents.length, Endian.little)
      ..setUint16(28, name.length, Endian.little)
      ..setUint32(42, local, Endian.little);
    central
      ..add(entry.buffer.asUint8List())
      ..add(name.codeUnits);
  }
  final centralAt = out.length;
  final centralBytes = central.toBytes();
  out.add(centralBytes);
  final end = ByteData(22)
    ..setUint32(0, 0x06054b50, Endian.little)
    ..setUint16(8, files.length, Endian.little)
    ..setUint16(10, files.length, Endian.little)
    ..setUint32(12, centralBytes.length, Endian.little)
    ..setUint32(16, centralAt, Endian.little);
  out.add(end.buffer.asUint8List());
  return out.toBytes();
}

void main() {
  final good = _elf([16384, 16384]);
  final bad = _elf([16384, 4096]);

  test('stored libraries at 16 KB offsets with 16 KB segments pass', () {
    final apk = _zip([
      ('AndroidManifest.xml', Uint8List(10), true),
      ('lib/arm64-v8a/libgood.so', good, false),
      ('lib/x86_64/libgood.so', good, false),
    ], storedAlign: 16384);
    expect(checkApk(apk), isEmpty);
  });

  test('a 4 KB LOAD segment fails', () {
    final apk = _zip([
      ('lib/arm64-v8a/libbad.so', bad, false),
    ], storedAlign: 16384);
    expect(checkApk(apk), [contains('lib/arm64-v8a/libbad.so has a LOAD')]);
  });

  test('a stored library at a 4 KB offset fails', () {
    final apk = _zip(
      [('lib/arm64-v8a/libgood.so', good, false)],
      storedAlign: 16384,
      shift: 4096,
    );
    expect(checkApk(apk), [contains('not a multiple of 16 KB')]);
  });

  test('a compressed library needs no offset, only segments', () {
    final apk = _zip([
      ('lib/arm64-v8a/libgood.so', good, true),
      ('lib/x86_64/libbad.so', bad, true),
    ]);
    expect(checkApk(apk), [contains('lib/x86_64/libbad.so has a LOAD')]);
  });

  test('32-bit ABIs are not checked', () {
    final apk = _zip([('lib/armeabi-v7a/libold.so', Uint8List(4), false)]);
    expect(checkApk(apk), isEmpty);
  });

  test('a file that is not a zip archive throws', () {
    expect(() => checkApk(Uint8List(100)), throwsFormatException);
  });
}
