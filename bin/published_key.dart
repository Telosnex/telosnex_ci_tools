/// Checks that a Kiln package, as published, computes the source key of
/// its manifest (native_artifacts/prebuilt.json). Otherwise every user's
/// build compiles from source: a file that .pubignore leaves out but the
/// key hashes (list it in native_artifacts/source_excludes.txt too).
///
/// dart run telosnex_ci_tools:published_key [package directory]
///
/// Takes the file list of `dart pub publish --dry-run` (exactly what pub
/// uploads), copies those files to a temporary directory, resolves it
/// offline and runs `dart run kiln:key` there. Exit 1 on a mismatch.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:telosnex_ci_tools/src/published_files.dart';

Future<void> main(List<String> args) async {
  final dir = p.absolute(args.isEmpty ? '.' : args.single);
  final manifest = File(p.join(dir, 'native_artifacts', 'prebuilt.json'));
  if (!manifest.existsSync()) {
    stdout.writeln('No native_artifacts/prebuilt.json: not a Kiln package.');
    return;
  }
  final want =
      (jsonDecode(manifest.readAsStringSync()) as Map)['sourceKey'] as String;

  final dryRun = await Process.run('dart', [
    'pub',
    'publish',
    '--dry-run',
  ], workingDirectory: dir);
  final files = publishedFiles('${dryRun.stdout}');
  if (files.isEmpty) {
    stderr.writeln('No file list in `dart pub publish --dry-run`:');
    stderr.writeln('${dryRun.stdout}\n${dryRun.stderr}');
    exit(1);
  }

  final tmp = Directory.systemTemp.createTempSync('published_key');
  var ok = false;
  try {
    for (final f in files) {
      final to = File(p.join(tmp.path, f))..parent.createSync(recursive: true);
      File(p.join(dir, f)).copySync(to.path);
    }
    final flutter = File(
      p.join(tmp.path, 'pubspec.yaml'),
    ).readAsStringSync().contains(RegExp(r'sdk:\s*flutter'));
    final get = await Process.run(flutter ? 'flutter' : 'dart', [
      'pub',
      'get',
      '--offline',
    ], workingDirectory: tmp.path);
    if (get.exitCode != 0) {
      stderr.writeln('pub get --offline failed in the copy:\n${get.stderr}');
      return;
    }
    final key = await Process.run('dart', [
      'run',
      'kiln:key',
    ], workingDirectory: tmp.path);
    final got = RegExp('[0-9a-f]{64}').firstMatch('${key.stdout}')?[0];
    if (got == want) {
      stdout.writeln(
        'The published files (${files.length}) compute the manifest\'s '
        'source key ${want.substring(0, 16)}.',
      );
      ok = true;
      return;
    }
    stderr.writeln(
      'error: the published files compute source key '
      '${got?.substring(0, 16)}, the manifest has ${want.substring(0, 16)}.\n'
      'Every build would compile from source. Compare '
      '`dart run kiln:key --list` here and in a copy (KEEP=1 keeps it); a file that '
      '.pubignore leaves out must be in native_artifacts/source_excludes.txt.',
    );
  } finally {
    if (Platform.environment.containsKey('KEEP')) {
      stderr.writeln('Kept: ${tmp.path}');
    } else {
      tmp.deleteSync(recursive: true);
    }
    if (!ok) exitCode = 1;
  }
}
