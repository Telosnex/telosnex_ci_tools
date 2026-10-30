/// dart run telosnex_ci_tools:publish_rename [--names tool/publish_names.yaml]
///     [--no-rekey] [--move-directories] [--tag <tag>] [repository]
///
/// Renames the packages of a repository checkout, in place, to the names
/// they publish under (tool/publish_names.yaml): pubspec names and
/// dependencies, `package:` URIs in Dart (imports and strings), build.yaml
/// builders, analyzer plugins, a plugin's implements and default_package,
/// and the native files Flutter finds by package name (podspec, Swift
/// package, CMake target, include directory). A published package's path
/// dependency on a package of the repository becomes ^version. A Kiln
/// package's manifest gets the renamed sources' key (--no-rekey: not).
/// --repository (the fork's URL) sets each renamed package's repository
/// to the fork's `published` branch (the publish workflow commits the
/// renamed tree there), and its issue_tracker to the fork's.
/// --move-directories also moves a package directory named after the old
/// name (and the paths to it): to build a renamed checkout's examples for
/// iOS and macOS, where Swift packages take their identity from the
/// directory name.
///
/// A string that is only an old name in published code (lib, bin, hook)
/// is renamed or kept by the line rules (strings.rename, strings.keep) of
/// tool/publish_names.yaml; one no rule matches is an error.
///
/// With --tag (a release tag: `v1.2.3`, or `<package>-v1.2.3`), also finds the
/// package the tag publishes and checks its version; writes
/// `package=<directory>` to \$GITHUB_OUTPUT. With no names file and
/// --tag, only that.
///
/// For the publish workflow, on a throwaway checkout: the fork keeps
/// upstream's names in git. Prints what changed. Exit 1 on an error.
library;

import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;
import 'package:telosnex_ci_tools/src/publish_rename.dart';

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption('names', defaultsTo: publishNamesPath)
    ..addFlag('rekey', defaultsTo: true)
    ..addFlag('move-directories')
    ..addOption('tag')
    ..addOption('repository')
    ..addFlag('help', abbr: 'h', negatable: false);
  final ArgResults args;
  try {
    args = parser.parse(arguments);
  } on FormatException catch (e) {
    stderr.writeln('${e.message}\n${parser.usage}');
    exit(2);
  }
  if (args.flag('help') || args.rest.length > 1) {
    stdout.writeln(parser.usage);
    exit(args.flag('help') ? 0 : 2);
  }
  final root = args.rest.isEmpty ? '.' : args.rest.single;
  final namesFile = File(p.join(root, args.option('names')!));
  final tag = args.option('tag');
  if (!namesFile.existsSync()) {
    if (tag == null) {
      stderr.writeln('No ${namesFile.path}.');
      exit(1);
    }
    stdout.writeln('No ${namesFile.path}: the names stay.');
    _target(root, tag);
    return;
  }
  final PublishNames names;
  try {
    names = parsePublishNames(namesFile.readAsStringSync());
  } on FormatException catch (e) {
    stderr.writeln('${namesFile.path}: ${e.message}');
    exit(1);
  }
  final report = await renameRepository(
    root,
    names,
    rekey: args.flag('rekey'),
    moveDirectories: args.flag('move-directories'),
    repository: args.option('repository'),
    ref: tag == null ? null : publishedBranch,
  );
  for (final MapEntry(:key, :value) in report.moved.entries) {
    stdout.writeln('moved $key -> $value');
  }
  stdout.writeln('${report.changed.length} files changed.');
  for (final (label, lines) in [
    ('renamed', report.renamedStrings),
    ('kept', report.keptStrings),
  ]) {
    if (lines.isEmpty) continue;
    stdout.writeln('\nStrings that are only an old name, $label:');
    for (final line in lines) {
      stdout.writeln('  $line');
    }
  }
  for (final error in report.errors) {
    stderr.writeln('error: $error');
  }
  if (report.errors.isNotEmpty) exit(1);
  if (tag != null) _target(root, tag);
}

/// Prints the package [tag] publishes, and writes `package=<dir>` to
/// \$GITHUB_OUTPUT when set. Exit 1 when the tag names none.
void _target(String root, String tag) {
  final (:dir, :error) = packageForTag(root, tag);
  if (dir == null) {
    stderr.writeln('error: $error');
    exit(1);
  }
  stdout.writeln(
    'Tag $tag publishes the package in ${dir == '.' ? 'the root' : dir}.',
  );
  final output = Platform.environment['GITHUB_OUTPUT'];
  if (output != null) {
    File(output).writeAsStringSync('package=$dir\n', mode: FileMode.append);
  }
}
