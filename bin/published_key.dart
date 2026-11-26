/// Checks that a Kiln package, as published, computes the source key of
/// its prebuilt files. Otherwise an app's `kiln:check` rejects the package
/// and every build compiles from source.
///
/// dart run telosnex_ci_tools:published_key [--against manifest|checkout]
///     [--kiln-package kiln] [package directory]
///
/// The key in a checkout hashes the files that git tracks. pub publishes
/// fewer: it leaves out a tracked file that a `.gitignore` or `.pubignore`
/// ignores, also one in a vendored tree. Such a file must be in
/// native_artifacts/source_excludes.txt.
///
/// Takes the file list of `dart pub publish --dry-run` (exactly what pub
/// uploads), copies those files to a temporary directory and computes the
/// key there. `--against manifest` (default) compares it with
/// native_artifacts/prebuilt.json. `--against checkout` compares it with
/// the key of the checkout: before a release, when the manifest is old.
/// Exit 1 on a mismatch, with the files that differ.
///
/// Run pub get in the package first.
library;

import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;
import 'package:telosnex_ci_tools/src/published_files.dart';
import 'package:telosnex_ci_tools/src/published_key.dart';

Future<void> main(List<String> arguments) async {
  final args =
      (ArgParser()
            ..addOption(
              'against',
              allowed: ['manifest', 'checkout'],
              defaultsTo: 'manifest',
            )
            ..addOption('kiln-package', defaultsTo: 'kiln'))
          .parse(arguments);
  final dir = p.absolute(args.rest.isEmpty ? '.' : args.rest.single);
  final againstManifest = args.option('against') == 'manifest';
  final manifest = File(p.join(dir, 'native_artifacts', 'prebuilt.json'));
  if (againstManifest && !manifest.existsSync()) {
    stdout.writeln('No native_artifacts/prebuilt.json: not a Kiln package.');
    return;
  }
  exitCode = 1;

  final keyTool = _keyTool(dir, args.option('kiln-package')!);
  final checkout = await _key(keyTool, dir);
  final want = againstManifest
      ? (jsonDecode(manifest.readAsStringSync()) as Map)['sourceKey'] as String
      : checkout.key;

  final dryRun = await Process.run('dart', [
    'pub',
    'publish',
    '--dry-run',
  ], workingDirectory: dir);
  final files = publishedFiles('${dryRun.stdout}');
  if (files.isEmpty) {
    stderr.writeln('No file list in `dart pub publish --dry-run`:');
    stderr.writeln('${dryRun.stdout}\n${dryRun.stderr}');
    return;
  }

  final tmp = Directory.systemTemp.createTempSync('published_key');
  try {
    for (final f in files) {
      final to = File(p.join(tmp.path, f))..parent.createSync(recursive: true);
      File(p.join(dir, f)).copySync(to.path);
    }
    final published = await _key(keyTool, tmp.path);
    final name = againstManifest ? 'the manifest' : 'the checkout';
    if (published.key == want) {
      stdout.writeln(
        'The published files (${files.length}) compute the source key of '
        '$name, ${want.substring(0, 16)}.',
      );
      exitCode = 0;
      return;
    }
    stderr.writeln(
      'error: the published files compute source key '
      '${published.key.substring(0, 16)}, $name has '
      '${want.substring(0, 16)}. An app would reject the package.',
    );
    final differences = keyDifferences(checkout, published);
    if (differences.isEmpty) {
      stderr.writeln(
        'The checkout computes the key of the published files: the '
        'manifest is of other sources. Make a Kiln release.',
      );
    } else {
      differences.forEach(stderr.writeln);
      stderr.writeln(
        'List a file that pub leaves out (.gitignore, .pubignore) in '
        'native_artifacts/source_excludes.txt, then make a Kiln release.',
      );
    }
  } finally {
    if (Platform.environment.containsKey('KEEP')) {
      stderr.writeln('Kept: ${tmp.path}');
    } else {
      tmp.deleteSync(recursive: true);
    }
  }
}

/// The arguments that run kiln's key command with the package resolution of
/// [dir]. Not `dart run kiln:key`: in a copy that needs pub get, and it can
/// run the package's build hook.
List<String> _keyTool(String dir, String kilnPackage) {
  final config = File(p.join(dir, '.dart_tool', 'package_config.json'));
  if (!config.existsSync()) {
    stderr.writeln('No ${config.path}: run pub get in the package first.');
    exit(1);
  }
  final packages = (jsonDecode(config.readAsStringSync()) as Map)['packages'];
  for (final package in packages as List) {
    if ((package as Map)['name'] != kilnPackage) continue;
    final root = config.parent.uri.resolve(
      '${package['rootUri']}'.replaceFirst(RegExp(r'/?$'), '/'),
    );
    return [
      '--packages=${config.path}',
      p.join(p.fromUri(root), 'bin', 'key.dart'),
    ];
  }
  stderr.writeln('The package does not depend on $kilnPackage.');
  exit(1);
}

Future<KeyListing> _key(List<String> keyTool, String dir) async {
  final result = await Process.run('dart', [
    ...keyTool,
    '--package',
    dir,
    '--list',
  ]);
  if (result.exitCode != 0) {
    stderr.writeln('The key command failed in $dir:\n${result.stderr}');
    exit(1);
  }
  return KeyListing.parse('${result.stdout}');
}
