/// Which repositories of an organization an app uses, and which of those
/// use telosnex_ci_tools (bin/repos.dart).
library;

import 'package:yaml/yaml.dart';

/// A git dependency on a GitHub repository, found in one file of the app.
final class RepoReference {
  const RepoReference({
    required this.owner,
    required this.repo,
    required this.file,
    required this.package,
    this.hosted = false,
  });

  /// From pub.dev (hosted), matched by package name; else a git URL.
  final bool hosted;

  /// As written in the URL (case as written; GitHub ignores it).
  final String owner;
  final String repo;

  /// The path of the pubspec.yaml, pubspec_overrides.yaml or pubspec.lock
  /// in the app repository.
  final String file;

  /// The Dart package that comes from the repository.
  final String package;

  /// From pubspec.lock only: a dependency of a dependency.
  bool get fromLock => file.endsWith('pubspec.lock');

  String get key => '${owner.toLowerCase()}/${repo.toLowerCase()}';
}

final _githubUrl = RegExp(
  r'github\.com[/:]([^/\s]+)/([^/\s]+?)(?:\.git)?/?$',
  caseSensitive: false,
);

/// Owner and repository of a GitHub git URL, else null.
(String, String)? parseGitHubUrl(String url) {
  final match = _githubUrl.firstMatch(url.trim());
  if (match == null) return null;
  return (match[1]!, match[2]!);
}

/// The GitHub git dependencies in [text], the contents of [file]: a
/// pubspec.yaml (dependencies, dev_dependencies, dependency_overrides), a
/// pubspec_overrides.yaml (dependency_overrides) or a pubspec.lock (every
/// git package, transitive ones too).
List<RepoReference> referencesIn(String file, String text) {
  final Object? root;
  try {
    root = loadYaml(text);
  } on YamlException {
    return const [];
  }
  if (root is! YamlMap) return const [];
  final out = <RepoReference>[];
  void add(String package, String? url) {
    if (url == null) return;
    final parsed = parseGitHubUrl(url);
    if (parsed == null) return;
    out.add(
      RepoReference(
        owner: parsed.$1,
        repo: parsed.$2,
        file: file,
        package: package,
      ),
    );
  }

  if (file.endsWith('pubspec.lock')) {
    final packages = root['packages'];
    if (packages is! YamlMap) return out;
    for (final entry in packages.entries) {
      final value = entry.value;
      if (value is! YamlMap || value['source'] != 'git') continue;
      final description = value['description'];
      if (description is YamlMap && description['url'] is String) {
        add('${entry.key}', description['url'] as String);
      }
    }
    return out;
  }
  for (final section in const [
    'dependencies',
    'dev_dependencies',
    'dependency_overrides',
  ]) {
    final deps = root[section];
    if (deps is! YamlMap) continue;
    for (final entry in deps.entries) {
      final value = entry.value;
      if (value is! YamlMap) continue;
      final git = value['git'];
      if (git is String) add('${entry.key}', git);
      if (git is YamlMap && git['url'] is String) {
        add('${entry.key}', git['url'] as String);
      }
    }
  }
  return out;
}

/// The hosted (pub.dev) packages of a pubspec.lock.
Set<String> hostedPackagesIn(String lock) {
  final Object? root;
  try {
    root = loadYaml(lock);
  } on YamlException {
    return const {};
  }
  final packages = root is YamlMap ? root['packages'] : null;
  if (packages is! YamlMap) return const {};
  return {
    for (final entry in packages.entries)
      if (entry.value is YamlMap &&
          (entry.value as YamlMap)['source'] == 'hosted')
        '${entry.key}',
  };
}

/// The `name:` of a pubspec.yaml, else null.
String? pubspecName(String pubspec) {
  try {
    final root = loadYaml(pubspec);
    final name = root is YamlMap ? root['name'] : null;
    return name is String ? name : null;
  } on YamlException {
    return null;
  }
}

/// The skipped repositories of status/repos.yaml, lowercase name to reason:
///
/// ```yaml
/// skip:
///   - repo: flutter_dev_scripts
///     reason: One script, now in telosnex dev/misc.
/// ```
///
/// Throws a [FormatException] on an entry without a repo or a reason.
Map<String, String> parseSkips(String yaml) => _parseReasons(yaml, 'skip');

/// The `upstream:` entries of status/repos.yaml: repositories that copy
/// their upstream instead of forking it on GitHub (e.g. a package of a
/// monorepo), lowercase name to `owner/repo[/path]`:
///
/// ```yaml
/// upstream:
///   - repo: google_fonts
///     upstream: flutter/packages/packages/google_fonts
/// ```
Map<String, String> parseUpstreams(String yaml) {
  final root = loadYaml(yaml);
  final list = root is YamlMap ? root['upstream'] : null;
  if (list == null) return const {};
  if (list is! YamlList) {
    throw const FormatException('upstream: is not a list.');
  }
  final out = <String, String>{};
  for (final entry in list) {
    final repo = entry is YamlMap ? entry['repo'] : null;
    final upstream = entry is YamlMap ? entry['upstream'] : null;
    if (repo is! String ||
        upstream is! String ||
        !RegExp(r'^[\w.-]+/[\w.-]+(/[\w./-]+)?$').hasMatch(upstream)) {
      throw FormatException(
        'Each upstream needs a repo and an upstream (owner/repo[/path]): '
        '$entry',
      );
    }
    out[repo.toLowerCase()] = upstream;
  }
  return out;
}

/// The follow-ups of status/repos.yaml (a `followup:` list of the same form
/// as `skip:`), lowercase name to what is left to do.
Map<String, String> parseFollowups(String yaml) =>
    _parseReasons(yaml, 'followup');

Map<String, String> _parseReasons(String yaml, String key) {
  final root = loadYaml(yaml);
  final list = root is YamlMap ? root[key] : null;
  if (list == null) return const {};
  if (list is! YamlList) throw FormatException('$key: is not a list.');
  final out = <String, String>{};
  for (final entry in list) {
    final repo = entry is YamlMap ? entry['repo'] : null;
    final reason = entry is YamlMap ? entry['reason'] : null;
    if (repo is! String || reason is! String || reason.trim().isEmpty) {
      throw FormatException('Each $key needs a repo and a reason: $entry');
    }
    out[repo.toLowerCase()] = reason.trim();
  }
  return out;
}

/// Whether [path] is a file [referencesIn] reads.
bool isDependencyFile(String path) {
  final name = path.split('/').last;
  return name == 'pubspec.yaml' ||
      name == 'pubspec_overrides.yaml' ||
      name == 'pubspec.lock';
}

/// The repositories of [org] that [workflow] uses as actions or reusable
/// workflows (`uses: <org>/<repo>[/path]@ref`), in lowercase.
Set<String> actionRepos(String workflow, String org) => {
  for (final match in RegExp(
    r'''^\s*(?:-\s+)?uses:\s*["']?([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)[/@]''',
    multiLine: true,
  ).allMatches(workflow))
    if (match[1]!.toLowerCase() == org.toLowerCase()) match[2]!.toLowerCase(),
};

enum ForkCategory {
  /// Uses telosnex_ci_tools.
  live('Live', 'Uses telosnex_ci_tools.'),

  /// The app uses it; no telosnex_ci_tools.
  missingCi(
    'Missing CI',
    'The app depends on it, but it does not use telosnex_ci_tools.',
  ),

  /// Used, no CI tools, and status/repos.yaml says what is left to do.
  followup(
    'Follow-up',
    'The app depends on it, it does not use telosnex_ci_tools, and '
        'status/repos.yaml records what is left to do.',
  ),

  /// Neither.
  unused(
    'Unused',
    'The app does not depend on it, and it does not use telosnex_ci_tools.',
  ),

  /// Listed in status/repos.yaml, with the reason.
  skipped(
    'Skipped',
    'Listed in status/repos.yaml: not expected to be a dependency or to use '
        'telosnex_ci_tools.',
  );

  const ForkCategory(this.title, this.description);
  final String title;
  final String description;
}

/// One repository of the organization.
final class OrgRepo {
  const OrgRepo({
    required this.name,
    required this.isFork,
    required this.isArchived,
    required this.usesCiTools,
    this.parent,
    this.pushedAt,
    this.references = const [],
    this.actionUsers = const {},
    this.packageName,
    this.skipReason,
    this.followup,
    this.copyOf,
  });

  /// The upstream (`owner/repo[/path]`) it copies, from status/repos.yaml;
  /// null when it is a GitHub fork or has no upstream.
  final String? copyOf;

  /// A GitHub fork, or a copy of an upstream.
  bool get hasUpstream => isFork || copyOf != null;

  /// What status/repos.yaml says is left to do; null when nothing.
  final String? followup;

  /// Why status/repos.yaml skips it; null when it does not.
  final String? skipReason;

  /// The `name:` of the root pubspec.yaml.
  final String? packageName;

  /// The repositories whose workflows use it as an action or reusable
  /// workflow. Does not change [category]: a forked action needs no CI tools,
  /// but it is not dead.
  final Set<String> actionUsers;

  final String name;
  final bool isFork;
  final bool isArchived;
  final bool usesCiTools;

  /// owner/name of the upstream, for forks.
  final String? parent;
  final DateTime? pushedAt;

  /// Where the app depends on it.
  final List<RepoReference> references;

  bool get used => references.isNotEmpty;

  /// Only through pubspec.lock: a dependency of a dependency.
  bool get usedTransitively => used && references.every((r) => r.fromLock);

  ForkCategory get category => skipReason != null
      ? ForkCategory.skipped
      : usesCiTools
      ? ForkCategory.live
      : used && followup != null
      ? ForkCategory.followup
      : used
      ? ForkCategory.missingCi
      : ForkCategory.unused;

  OrgRepo withUses(
    List<RepoReference> references,
    Set<String> actionUsers, {
    String? skipReason,
    String? followup,
    String? copyOf,
  }) => OrgRepo(
    name: name,
    isFork: isFork,
    isArchived: isArchived,
    usesCiTools: usesCiTools,
    parent: parent,
    pushedAt: pushedAt,
    references: references,
    actionUsers: actionUsers,
    skipReason: skipReason,
    followup: followup,
    copyOf: copyOf,
  );

  Map<String, Object?> toJson() => {
    'name': name,
    'category': category.name,
    'isFork': isFork,
    'isArchived': isArchived,
    'parent': parent,
    'copyOf': ?copyOf,
    'pushedAt': pushedAt?.toIso8601String(),
    'usesCiTools': usesCiTools,
    'usedTransitively': usedTransitively,
    'references': [
      for (final r in references)
        {'file': r.file, 'package': r.package, 'hosted': r.hosted},
    ],
    'actionUsers': [...actionUsers]..sort(),
    'skipReason': ?skipReason,
    'followup': ?followup,
  };
}

/// The report: one table per category, by name.
String renderForks(
  List<OrgRepo> repos, {
  required String org,
  required String app,
  required String appRef,
}) {
  final out = StringBuffer()
    ..writeln('# $org repositories by use')
    ..writeln()
    ..writeln(
      'Uses: git dependencies in the pubspec.yaml, pubspec_overrides.yaml '
      'and pubspec.lock files of $app at $appRef. "lock only": a dependency '
      'of a dependency. "pub.dev": not a fork, and the app uses its package '
      'from pub.dev. CI tools: a workflow on the default branch uses '
      'Telosnex/telosnex_ci_tools. Action of: a workflow (of the app or of a '
      'repository of $org) uses it as an action or reusable workflow; that '
      'does not change the category. Fork of: — for a repository of '
      '$org that is not a fork; "(copy)": a copy of the upstream, not a '
      'GitHub fork (status/repos.yaml upstream:).',
    )
    ..writeln()
    ..writeln(
      '${[for (final c in ForkCategory.values) '${c.title}: ${repos.where((r) => r.category == c).length}'].join(' · ')} '
      '(${repos.length} repositories, '
      '${repos.where((r) => r.hasUpstream).length} forks)',
    );
  for (final category in ForkCategory.values) {
    final rows = repos.where((r) => r.category == category).toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    out
      ..writeln()
      ..writeln('## ${category.title} (${rows.length})')
      ..writeln()
      ..writeln(category.description)
      ..writeln();
    if (rows.isEmpty) continue;
    out
      ..writeln(
        '| Repository | Fork of | Used by $app | Action of | Last push |'
        '${_noted(category) ? ' Reason |' : ''}',
      )
      ..writeln('|---|---|---|---|---|${_noted(category) ? '---|' : ''}');
    for (final repo in rows) {
      final packages = {for (final r in repo.references) r.package}.toList()
        ..sort();
      final notes = [
        if (repo.references.isNotEmpty &&
            repo.references.every((r) => r.hosted))
          'pub.dev',
        if (repo.usedTransitively) 'lock only',
      ];
      final use = !repo.used
          ? '—'
          : '${packages.join(', ')}${notes.isEmpty ? '' : ' (${notes.join(', ')})'}';
      final name =
          '[${repo.name}](https://github.com/$org/${repo.name})'
          '${repo.isArchived ? ' (archived)' : ''}';
      final parent = repo.copyOf != null
          ? _copyLink(repo.copyOf!)
          : repo.parent == null
          ? (repo.isFork ? '?' : '—')
          : '[${repo.parent}](https://github.com/${repo.parent})';
      final pushed = repo.pushedAt?.toIso8601String().substring(0, 10) ?? '?';
      final actions = repo.actionUsers.isEmpty
          ? '—'
          : ([...repo.actionUsers]..sort()).join(', ');
      final note = repo.skipReason ?? repo.followup;
      final reason = !_noted(category) || note == null
          ? ''
          : ' ${note.replaceAll('|', r'\|').replaceAll('\n', ' ')} |';
      out.writeln('| $name | $parent | $use | $actions | $pushed |$reason');
    }
  }
  return out.toString();
}

/// Whether the category's table has a Reason column.
bool _noted(ForkCategory category) =>
    category == ForkCategory.skipped || category == ForkCategory.followup;

/// A link to [upstream] (`owner/repo[/path]`), marked as a copy.
String _copyLink(String upstream) {
  final parts = upstream.split('/');
  final repo = '${parts[0]}/${parts[1]}';
  final path = parts.skip(2).join('/');
  final url = path.isEmpty
      ? 'https://github.com/$repo'
      : 'https://github.com/$repo/tree/HEAD/$path';
  return '[$upstream]($url) (copy)';
}
