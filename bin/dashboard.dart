import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;
import 'package:telosnex_ci_tools/src/dashboard.dart';
import 'package:telosnex_ci_tools/src/dashboard_fetch.dart';

/// dart run telosnex_ci_tools:dashboard [--config status/packages.yaml]
///     [--out dir] [--packages-md status/packages.md]
///
/// Reads the packages in status/packages.yaml from GitHub: whether their
/// default branch uses Kiln and CI tools, and their newest CI runs. Prints
/// the dashboard (Markdown) of the packages that use either; with --out,
/// writes README.md and dashboard.json to that directory instead. With
/// --packages-md, writes the packages table, unless a package could not be
/// read (then the file stays). A package that could not be read is a
/// warning on the dashboard, not a failure. The pub.dev column: the packages
/// of --publisher (telosnex.com) whose pubspec's repository is the
/// package's; when pub.dev cannot be read, a warning and `?`. The token: GITHUB_TOKEN or
/// GH_TOKEN, else `gh auth token`.
Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption('config', defaultsTo: 'status/packages.yaml')
    ..addOption('out')
    ..addOption('packages-md')
    ..addOption('publisher', defaultsTo: 'telosnex.com')
    ..addFlag('help', abbr: 'h', negatable: false);
  final args = parser.parse(arguments);
  if (args.flag('help')) {
    stdout
      ..writeln(
        'dart run telosnex_ci_tools:dashboard [--config status/packages.yaml] '
        '[--out dir] [--packages-md status/packages.md]',
      )
      ..writeln(parser.usage);
    return;
  }
  final packages = readDashboardConfig(
    File(args.option('config')!).readAsStringSync(),
  );
  final github = await GitHubReader.fromEnvironment();
  final prefix = Platform.environment['GITHUB_ACTIONS'] == 'true'
      ? '::warning::'
      : 'Warning: ';
  final publisher = args.option('publisher')!;
  final pubFuture = fetchPublisherPackages(publisher).then<List<PubPackage>?>(
    (packages) => packages,
    onError: (Object error) {
      stderr.writeln('${prefix}pub.dev publisher $publisher: $error');
      return null;
    },
  );
  final List<PackageStatus> statuses;
  try {
    statuses = await Future.wait([
      for (final package in packages) fetchPackage(github, package),
    ]);
  } finally {
    github.close();
  }
  final published = await pubFuture;
  final now = DateTime.now();
  final shown = [
    for (final status in statuses)
      if (status.adopted || status.error != null) status,
  ];
  final markdown = renderDashboard(shown, now, published: published);
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
        'packages': [for (final status in shown) status.toJson()],
        'published': [...?published?.map((p) => p.toJson())],
      })}\n',
    );
    stdout.writeln('Wrote ${p.join(out, 'README.md')} and dashboard.json.');
  }
  final unreadable = statuses.where((status) => status.error != null).toList();
  for (final status in unreadable) {
    stderr.writeln('$prefix${status.package.repo}: ${status.error}');
  }
  final packagesMd = args.option('packages-md');
  if (packagesMd != null) {
    if (unreadable.isEmpty) {
      File(packagesMd).writeAsStringSync(renderPackages(statuses));
      stdout.writeln('Wrote $packagesMd.');
    } else {
      stderr.writeln('${prefix}Kept $packagesMd: a package could not be read.');
    }
  }
}
