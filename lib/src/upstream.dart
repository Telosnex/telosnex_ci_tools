/// The upstream watch (`dart run telosnex_ci_tools:upstream_watch`): tells
/// a package when the code that it pins from another project has an
/// update. Each package lists its sources in `.github/upstream.yaml`:
///
/// ```yaml
/// sources:
///   - name: FFmpeg
///     tags: https://github.com/FFmpeg/FFmpeg.git
///     version: 'n(\d+(?:\.\d+)*)'
///     pin: {file: tool/fetch_ffmpeg.sh, pattern: 'revision=([0-9a-f]{40})'}
///   - name: wllama
///     branch: https://github.com/ngxson/wllama
///     pin: {file: web_build/wllama.json, pattern: '"commit": "([0-9a-f]{40})"'}
///     lag_days: 7
///   - name: WebRTC
///     run: dart .github/vendor_watch.dart
/// ```
///
/// A source has one kind:
///
/// - `tags`: a git URL. An update is a tag whose name matches `version`
///   (the whole name; one group, the version) and whose version is newer
///   than the pin at the `alert` level. The pin is a version, or the commit
///   of a tag.
/// - `branch`: a GitHub URL, and optional `ref` (default: the default
///   branch). An update is a commit after the pin that is older than
///   `lag_days` (default 0).
/// - `run`: a bash command, run in the package. Exit 0: up to date; 1: an
///   update, and its output says which; other: an error.
///
/// `pin` is a value, or `{file, pattern}`: the first group of the first
/// match of `pattern` in `file`. So the pin stays where the build reads it.
/// `seen` (optional) is a version or commit to treat as taken: set it to
/// skip an update until a newer one.
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'dashboard_fetch.dart' show GitHubReader;

/// Where a package lists its upstream sources. In `.github/` so that it is
/// not in the Kiln source key.
const upstreamFile = '.github/upstream.yaml';

/// How large a version change must be to alert.
enum AlertLevel { major, minor, patch }

final class UpstreamException implements Exception {
  UpstreamException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// One source of `.github/upstream.yaml`.
sealed class UpstreamSource {
  UpstreamSource(this.name);
  final String name;
}

final class TagsSource extends UpstreamSource {
  TagsSource(
    super.name, {
    required this.url,
    required this.pin,
    required this.version,
    required this.alert,
    this.seen,
  });
  final String url;
  final String pin;
  final RegExp version;
  final AlertLevel alert;
  final String? seen;
}

final class BranchSource extends UpstreamSource {
  BranchSource(
    super.name, {
    required this.repo,
    required this.pin,
    this.ref,
    this.lagDays = 0,
    this.seen,
  });

  /// `owner/name` on GitHub.
  final String repo;
  final String pin;
  final String? ref;
  final int lagDays;
  final String? seen;
}

final class RunSource extends UpstreamSource {
  RunSource(super.name, this.command);
  final String command;
}

/// The result for one source.
final class UpstreamResult {
  const UpstreamResult(
    this.name, {
    required this.status,
    required this.summary,
    this.detail = '',
  });
  final String name;
  final UpstreamStatus status;

  /// One line: the pin and what upstream has.
  final String summary;

  /// More lines: the new tags or commits, or the command's output.
  final String detail;
}

enum UpstreamStatus { upToDate, update, error }

final _sha = RegExp(r'^[0-9a-f]{40}$');
final _defaultVersion = r'v?(\d+(?:\.\d+)+)';

/// The sources of [yamlText], with pins read from [packageRoot].
List<UpstreamSource> parseUpstream(String yamlText, String packageRoot) {
  final doc = loadYaml(yamlText);
  if (doc is! YamlMap || doc['sources'] is! YamlList) {
    throw UpstreamException('$upstreamFile: needs a `sources` list.');
  }
  return [
    for (final (i, entry) in (doc['sources'] as YamlList).indexed)
      _source(entry, i, packageRoot),
  ];
}

UpstreamSource _source(Object? entry, int index, String root) {
  if (entry is! YamlMap) {
    throw UpstreamException('$upstreamFile: source ${index + 1} is not a map.');
  }
  final name = entry['name'];
  if (name is! String || name.isEmpty) {
    throw UpstreamException('$upstreamFile: source ${index + 1} has no name.');
  }
  final kinds = ['tags', 'branch', 'run'].where(entry.containsKey).toList();
  if (kinds.length != 1) {
    throw UpstreamException(
      '$name: needs exactly one of tags, branch, run (has '
      '${kinds.isEmpty ? 'none' : kinds.join(', ')}).',
    );
  }
  String? text(String key) {
    final value = entry[key];
    if (value == null) return null;
    if (value is String || value is num) return '$value';
    throw UpstreamException('$name: $key must be a string.');
  }

  switch (kinds.single) {
    case 'run':
      return RunSource(name, text('run')!);
    case 'tags':
      final pattern = text('version') ?? _defaultVersion;
      final RegExp version;
      try {
        version = RegExp('^(?:$pattern)\$');
      } on FormatException catch (e) {
        throw UpstreamException('$name: version is not a regex: ${e.message}');
      }
      final alert = text('alert') ?? 'minor';
      return TagsSource(
        name,
        url: text('tags')!,
        pin: readPin(entry['pin'], root, name),
        version: version,
        alert: AlertLevel.values.firstWhere(
          (l) => l.name == alert,
          orElse: () => throw UpstreamException(
            '$name: alert must be major, minor or patch.',
          ),
        ),
        seen: text('seen'),
      );
    default:
      final url = text('branch')!;
      final m = RegExp(
        r'^https://github\.com/([^/]+/[^/]+?)(?:\.git)?/?$',
      ).firstMatch(url);
      if (m == null) {
        throw UpstreamException('$name: branch must be a GitHub URL.');
      }
      final pin = readPin(entry['pin'], root, name);
      if (!_sha.hasMatch(pin)) {
        throw UpstreamException('$name: the pin of a branch is a commit.');
      }
      final lag = entry['lag_days'] ?? 0;
      if (lag is! int || lag < 0) {
        throw UpstreamException('$name: lag_days must be a whole number.');
      }
      return BranchSource(
        name,
        repo: m[1]!,
        pin: pin,
        ref: text('ref'),
        lagDays: lag,
        seen: text('seen'),
      );
  }
}

/// The pin of a source: a value, or `{file, pattern}`.
String readPin(Object? pin, String root, String name) {
  if (pin is String || pin is num) return '$pin';
  if (pin is! YamlMap || pin['file'] is! String || pin['pattern'] is! String) {
    throw UpstreamException(
      '$name: pin must be a value or {file: ..., pattern: ...}.',
    );
  }
  final file = File(p.join(root, pin['file'] as String));
  if (!file.existsSync()) {
    throw UpstreamException('$name: pin file ${pin['file']} does not exist.');
  }
  final match = RegExp(
    pin['pattern'] as String,
    multiLine: true,
  ).firstMatch(file.readAsStringSync());
  if (match == null || match.groupCount < 1 || match[1] == null) {
    throw UpstreamException(
      '$name: pattern ${pin['pattern']} has no match (with a group) in '
      '${pin['file']}.',
    );
  }
  return match[1]!;
}

/// The numbers of a version: [9, 0] for '9.0'.
List<int> versionParts(String version) => [
  for (final part in version.split(RegExp(r'[^0-9]+')))
    if (part.isNotEmpty) int.parse(part),
];

/// Compares [a] and [b] on their first [length] numbers (missing ones are
/// 0); all of them when [length] is null.
int compareVersions(List<int> a, List<int> b, [int? length]) {
  final n = length ?? (a.length > b.length ? a.length : b.length);
  for (var i = 0; i < n; i++) {
    final x = i < a.length ? a[i] : 0;
    final y = i < b.length ? b[i] : 0;
    if (x != y) return x.compareTo(y);
  }
  return 0;
}

int? _levelLength(AlertLevel level) => switch (level) {
  AlertLevel.major => 1,
  AlertLevel.minor => 2,
  AlertLevel.patch => null,
};

/// The tags of a `git ls-remote --tags` output: name to commit, with
/// annotated tags at the commit that they point to.
Map<String, String> parseLsRemote(String output) {
  final tags = <String, String>{};
  for (final line in output.split('\n')) {
    final parts = line.split('\t');
    if (parts.length != 2 || !parts[1].startsWith('refs/tags/')) continue;
    var name = parts[1].substring('refs/tags/'.length);
    final peeled = name.endsWith('^{}');
    if (peeled) name = name.substring(0, name.length - 3);
    // The peeled line names the commit; it wins over the tag object.
    if (peeled || !tags.containsKey(name)) tags[name] = parts[0];
  }
  return tags;
}

/// The result of a `tags` source, from the tags of its repository.
UpstreamResult checkTags(TagsSource source, Map<String, String> tags) {
  final versions = <String, String>{}; // version -> tag
  for (final tag in tags.keys) {
    final m = source.version.firstMatch(tag);
    if (m != null && m.groupCount >= 1 && m[1] != null) versions[m[1]!] = tag;
  }
  if (versions.isEmpty) {
    return UpstreamResult(
      source.name,
      status: UpstreamStatus.error,
      summary: 'No tag of ${source.url} matches ${source.version.pattern}.',
    );
  }
  String? pinned;
  if (_sha.hasMatch(source.pin)) {
    for (final MapEntry(key: version, value: tag) in versions.entries) {
      if (tags[tag] == source.pin) pinned = version;
    }
    if (pinned == null) {
      return UpstreamResult(
        source.name,
        status: UpstreamStatus.error,
        summary:
            'The pin ${source.pin.substring(0, 10)} is not the commit of a '
            'version tag.',
      );
    }
  } else {
    pinned = source.pin;
  }
  final base = [
    versionParts(pinned),
    if (source.seen != null) versionParts(source.seen!),
  ].reduce((a, b) => compareVersions(a, b) >= 0 ? a : b);
  final sorted = versions.keys.toList()
    ..sort((a, b) => compareVersions(versionParts(a), versionParts(b)));
  final newer = [
    for (final v in sorted)
      if (compareVersions(versionParts(v), base, _levelLength(source.alert)) >
          0)
        v,
  ];
  final newest = sorted.last;
  if (newer.isEmpty) {
    return UpstreamResult(
      source.name,
      status: UpstreamStatus.upToDate,
      summary:
          'Pinned $pinned; newest $newest'
          '${source.seen == null ? '' : ', seen ${source.seen}'}.',
    );
  }
  return UpstreamResult(
    source.name,
    status: UpstreamStatus.update,
    summary:
        'Pinned $pinned; newest $newest (${newer.length} newer '
        'release(s), alerting on ${source.alert.name} changes).',
    detail: [for (final v in newer) '${versions[v]}'].join('\n'),
  );
}

/// The result of a `branch` source, from GitHub.
Future<UpstreamResult> checkBranch(
  BranchSource source,
  GitHubReader github, {
  DateTime? now,
}) async {
  final ref =
      source.ref ??
      ((await github.get('repos/${source.repo}'))?['default_branch']
          as String?);
  if (ref == null) {
    return UpstreamResult(
      source.name,
      status: UpstreamStatus.error,
      summary: '${source.repo} not found.',
    );
  }
  final base = source.seen ?? source.pin;
  final compare = await github.get('repos/${source.repo}/compare/$base...$ref');
  if (compare == null) {
    return UpstreamResult(
      source.name,
      status: UpstreamStatus.error,
      summary: '${base.substring(0, 10)} is not in ${source.repo}.',
    );
  }
  final status = compare['status'] as String;
  if (status == 'behind' || status == 'diverged') {
    return UpstreamResult(
      source.name,
      status: UpstreamStatus.error,
      summary: '${base.substring(0, 10)} is not on $ref ($status).',
    );
  }
  final ahead = compare['ahead_by'] as int;
  final commits = (compare['commits'] as List).cast<Map<String, Object?>>();
  final pinText =
      'Pinned ${source.pin.substring(0, 10)}'
      '${source.seen == null ? '' : ', seen ${source.seen!.substring(0, 10)}'}';
  if (ahead == 0) {
    return UpstreamResult(
      source.name,
      status: UpstreamStatus.upToDate,
      summary: '$pinText; $ref has nothing newer.',
    );
  }
  DateTime date(Map<String, Object?> c) => DateTime.parse(
    ((c['commit'] as Map)['committer'] as Map)['date'] as String,
  );
  final oldest = date(commits.first);
  final age = (now ?? DateTime.now().toUtc()).difference(oldest).inDays;
  final lines = [
    for (final c in commits.reversed.take(20))
      '${(c['sha'] as String).substring(0, 10)} '
          '${date(c).toIso8601String().substring(0, 10)} '
          '${((c['commit'] as Map)['message'] as String).split('\n').first}',
    if (commits.length > 20) '... ${ahead - 20} more',
  ];
  if (age < source.lagDays) {
    return UpstreamResult(
      source.name,
      status: UpstreamStatus.upToDate,
      summary:
          '$pinText; $ref is $ahead commit(s) ahead, the oldest $age day(s) '
          'old (alert after ${source.lagDays}).',
    );
  }
  return UpstreamResult(
    source.name,
    status: UpstreamStatus.update,
    summary:
        '$pinText; $ref is $ahead commit(s) ahead, the oldest $age day(s) '
        'old.',
    detail: lines.join('\n'),
  );
}

/// The result of a `run` source.
Future<UpstreamResult> checkRun(RunSource source, String root) async {
  final r = await Process.run('bash', [
    '-euo',
    'pipefail',
    '-c',
    source.command,
  ], workingDirectory: root);
  final out = '${r.stdout}${r.stderr}'.trim();
  final status = switch (r.exitCode) {
    0 => UpstreamStatus.upToDate,
    1 => UpstreamStatus.update,
    _ => UpstreamStatus.error,
  };
  return UpstreamResult(
    source.name,
    status: status,
    summary: switch (status) {
      UpstreamStatus.upToDate => 'The command reports no update.',
      UpstreamStatus.update => 'The command reports an update (output below).',
      UpstreamStatus.error => 'The command exited ${r.exitCode}.',
    },
    detail: out,
  );
}

/// The job summary, in Markdown.
String upstreamSummary(List<UpstreamResult> results) {
  final updates = results.where((r) => r.status == UpstreamStatus.update);
  final errors = results.where((r) => r.status == UpstreamStatus.error);
  final b = StringBuffer(
    updates.isEmpty && errors.isEmpty
        ? '## Upstream: up to date\n\n'
        : '## Upstream: ${updates.length} update(s), ${errors.length} '
              'error(s)\n\n',
  );
  b
    ..writeln('| Source | Status | |')
    ..writeln('|---|---|---|');
  for (final r in results) {
    final status = switch (r.status) {
      UpstreamStatus.upToDate => 'up to date',
      UpstreamStatus.update => '**update**',
      UpstreamStatus.error => '**error**',
    };
    b.writeln('| ${r.name} | $status | ${r.summary.replaceAll('|', r'\|')} |');
  }
  for (final r in results) {
    if (r.status == UpstreamStatus.upToDate || r.detail.isEmpty) continue;
    b
      ..writeln('\n### ${r.name}\n')
      ..writeln('```\n${r.detail}\n```');
  }
  b.writeln(
    '\nTo skip an update until a newer one, set `seen` of the source in '
    '`$upstreamFile`.',
  );
  return '$b';
}

/// A short form of a watch annotation, for the dashboard: title
/// `<source>: update` or `<source>: error`, message the summary of
/// [checkTags], [checkBranch] or [checkRun]. Null when it is not one.
String? upstreamNote(String title, String message) {
  final t = RegExp(r'^(.+): (update|error)$').firstMatch(title);
  if (t == null) return null;
  final name = t[1]!;
  if (t[2] == 'error') return '$name: error: $message';
  final tags = RegExp(r'^Pinned (\S+); newest (\S+) \(').firstMatch(message);
  if (tags != null) return '$name ${tags[1]} → ${tags[2]}';
  final branch = RegExp(
    r'; (\S+) is (\d+) commit\(s\) ahead, the oldest (\d+) day\(s\) old\.$',
  ).firstMatch(message);
  if (branch != null) {
    return '$name: ${branch[2]} commits behind ${branch[1]}, the oldest '
        '${branch[3]} days old';
  }
  return '$name: update';
}
