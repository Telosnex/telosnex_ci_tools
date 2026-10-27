import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;
import 'package:telosnex_ci_tools/src/dashboard.dart';
import 'package:telosnex_ci_tools/src/dashboard_fetch.dart';

/// dart run telosnex_ci_tools:dashboard [--config dashboard.yaml] [--out dir]
///
/// Reads the newest CI runs of the packages in dashboard.yaml from GitHub
/// and prints the dashboard (Markdown). With --out, writes README.md and
/// dashboard.json to that directory instead. The token: GITHUB_TOKEN or
/// GH_TOKEN, else `gh auth token`.
Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption('config', defaultsTo: 'dashboard.yaml')
    ..addOption('out')
    ..addFlag('help', abbr: 'h', negatable: false);
  final args = parser.parse(arguments);
  if (args.flag('help')) {
    stdout
      ..writeln(
        'dart run telosnex_ci_tools:dashboard [--config dashboard.yaml] '
        '[--out dir]',
      )
      ..writeln(parser.usage);
    return;
  }
  final packages = readDashboardConfig(
    File(args.option('config')!).readAsStringSync(),
  );
  final github = await GitHubReader.fromEnvironment();
  final List<PackageStatus> statuses;
  try {
    statuses = await Future.wait([
      for (final package in packages) fetchPackage(github, package),
    ]);
  } finally {
    github.close();
  }
  final now = DateTime.now();
  final markdown = renderDashboard(statuses, now);
  final out = args.option('out');
  if (out == null) {
    stdout.write(markdown);
  } else {
    Directory(out).createSync(recursive: true);
    File(p.join(out, 'README.md')).writeAsStringSync(markdown);
    File(p.join(out, 'dashboard.json')).writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert({
        'version': 1,
        'updatedAt': now.toUtc().toIso8601String(),
        'packages': [for (final status in statuses) status.toJson()],
      })}\n',
    );
    stdout.writeln('Wrote ${p.join(out, 'README.md')} and dashboard.json.');
  }
  final unreadable = statuses.where((status) => status.error != null);
  for (final status in unreadable) {
    stderr.writeln('${status.package.repo}: ${status.error}');
  }
  if (unreadable.isNotEmpty) exitCode = 1;
}
