/// dart run telosnex_ci_tools:upstream_watch [package directory]
///
/// Checks the upstream sources of `.github/upstream.yaml` (see
/// lib/src/upstream.dart). Exits 1 when one has an update or an error, so
/// the daily workflow fails and GitHub sends an email. Writes a table to
/// GITHUB_STEP_SUMMARY when it is set.
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:telosnex_ci_tools/src/dashboard_fetch.dart';
import 'package:telosnex_ci_tools/src/upstream.dart';

Future<void> main(List<String> args) async {
  final root = p.absolute(args.isEmpty ? '.' : args.single);
  final file = File(p.join(root, upstreamFile));
  if (!file.existsSync()) {
    stderr.writeln('No $upstreamFile in $root.');
    exitCode = 2;
    return;
  }
  final List<UpstreamSource> sources;
  try {
    sources = parseUpstream(file.readAsStringSync(), root);
  } on UpstreamException catch (e) {
    stderr.writeln(e.message);
    exitCode = 2;
    return;
  }
  final github = await GitHubReader.fromEnvironment();
  final results = <UpstreamResult>[];
  try {
    for (final source in sources) {
      try {
        results.add(switch (source) {
          TagsSource() => checkTags(source, await _lsRemote(source.url)),
          BranchSource() => await checkBranch(source, github.getJson),
          RunSource() => await checkRun(source, root),
        });
      } on Exception catch (e) {
        results.add(
          UpstreamResult(
            source.name,
            status: UpstreamStatus.error,
            summary: '$e',
          ),
        );
      }
    }
  } finally {
    github.close();
  }

  final ci = Platform.environment['GITHUB_ACTIONS'] == 'true';
  for (final r in results) {
    final label = switch (r.status) {
      UpstreamStatus.upToDate => 'ok    ',
      UpstreamStatus.update => 'UPDATE',
      UpstreamStatus.error => 'ERROR ',
    };
    stdout.writeln('$label ${r.name}: ${r.summary}');
    if (r.status != UpstreamStatus.upToDate && r.detail.isNotEmpty) {
      stdout.writeln(r.detail.split('\n').map((l) => '         $l').join('\n'));
    }
    if (ci && r.status != UpstreamStatus.upToDate) {
      final kind = r.status == UpstreamStatus.update ? 'update' : 'error';
      stdout.writeln('::error title=${r.name}: $kind::${r.summary}');
    }
  }
  final summary = Platform.environment['GITHUB_STEP_SUMMARY'];
  if (summary != null && summary.isNotEmpty) {
    File(
      summary,
    ).writeAsStringSync(upstreamSummary(results), mode: FileMode.append);
  }
  exitCode = results.every((r) => r.status == UpstreamStatus.upToDate) ? 0 : 1;
}

Future<Map<String, String>> _lsRemote(String url) async {
  final r = await Process.run('git', ['ls-remote', '--tags', url]);
  if (r.exitCode != 0) {
    throw UpstreamException('git ls-remote $url: ${'${r.stderr}'.trim()}');
  }
  return parseLsRemote(r.stdout as String);
}
