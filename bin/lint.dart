import 'dart:io';

import 'package:args/args.dart';
import 'package:telosnex_ci_tools/src/lint.dart';

/// dart run telosnex_ci_tools:lint [repository...]
///
/// Checks the workflow files of each repository against the Telosnex
/// conventions. Exits with 1 if it finds a violation.
void main(List<String> arguments) {
  final parser = ArgParser()
    ..addFlag('help', abbr: 'h', negatable: false)
    ..addFlag(
      'annotations',
      help: 'Print GitHub annotations. Default: on in GitHub Actions.',
      defaultsTo: Platform.environment['GITHUB_ACTIONS'] == 'true',
    );
  final args = parser.parse(arguments);
  if (args.flag('help')) {
    stdout
      ..writeln('dart run telosnex_ci_tools:lint [repository...]')
      ..writeln(parser.usage);
    return;
  }
  final repos = args.rest.isEmpty ? ['.'] : args.rest;
  var count = 0;
  for (final repo in repos) {
    for (final finding in lintRepository(repo)) {
      count++;
      final label = repos.length == 1 ? '' : '$repo: ';
      stdout.writeln(
        args.flag('annotations') ? finding.toAnnotation() : '$label$finding',
      );
    }
  }
  if (count > 0) {
    stdout.writeln('$count findings.');
    exitCode = 1;
  }
}
