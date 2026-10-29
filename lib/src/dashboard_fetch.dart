import 'dart:convert';
import 'dart:io';

import 'package:yaml/yaml.dart';

import 'dashboard.dart';

/// Reads status/packages.yaml.
List<DashboardPackage> readDashboardConfig(String yaml) {
  final root = loadYaml(yaml);
  final packages = root is YamlMap ? root['packages'] : null;
  if (packages is! YamlList) {
    throw const FormatException('packages.yaml: no packages list.');
  }
  List<String>? files(YamlMap entry, String key) {
    final value = entry[key];
    if (value == null) return null;
    if (value is! YamlList) {
      throw FormatException('packages.yaml: $key must be a list.');
    }
    return [for (final file in value) '$file'];
  }

  return [
    for (final entry in packages)
      if (entry is YamlMap && entry['repo'] is String)
        DashboardPackage(
          repo: entry['repo'] as String,
          tests: files(entry, 'tests') ?? const ['unit.yml', 'integration.yml'],
          checks: files(entry, 'checks') ?? const ['kiln_check.yml'],
          releases: files(entry, 'releases') ?? const ['kiln_release.yml'],
        )
      else
        throw FormatException('packages.yaml: $entry has no repo.'),
  ];
}

/// GitHub's REST API, read only.
final class GitHubReader {
  GitHubReader(this.token);

  final String? token;
  final _client = HttpClient()..userAgent = 'telosnex_ci_tools-dashboard';

  /// GITHUB_TOKEN or GH_TOKEN, else `gh auth token`, else none (60 requests
  /// an hour).
  static Future<GitHubReader> fromEnvironment() async {
    final env = Platform.environment;
    var token = env['GITHUB_TOKEN'] ?? env['GH_TOKEN'];
    if (token == null || token.isEmpty) {
      try {
        final gh = await Process.run('gh', ['auth', 'token']);
        if (gh.exitCode == 0) token = (gh.stdout as String).trim();
      } on ProcessException {
        // No gh.
      }
    }
    return GitHubReader(token == null || token.isEmpty ? null : token);
  }

  void close() => _client.close();

  /// Null on 404.
  Future<Map<String, Object?>?> get(String path) async =>
      await getJson(path) as Map<String, Object?>?;

  /// The JSON of [path], null on 404. Tries 3 times on a 5xx or a network
  /// error: GitHub answers a 502 now and then.
  Future<Object?> getJson(String path) async {
    for (var attempt = 1; ; attempt++) {
      try {
        final request = await _client.getUrl(
          Uri.parse('https://api.github.com/$path'),
        );
        request.headers
          ..set('Accept', 'application/vnd.github+json')
          ..set('X-GitHub-Api-Version', '2022-11-28');
        if (token != null) {
          request.headers.set('Authorization', 'Bearer $token');
        }
        final response = await request.close();
        final body = await response.transform(utf8.decoder).join();
        if (response.statusCode == 404) return null;
        if (response.statusCode >= 500 && attempt < 3) {
          await Future<void>.delayed(Duration(seconds: 2 * attempt));
          continue;
        }
        if (response.statusCode != 200) {
          throw _GitHubError('GET $path: ${response.statusCode} $body');
        }
        return jsonDecode(body);
      } on IOException {
        if (attempt == 3) rethrow;
        await Future<void>.delayed(Duration(seconds: 2 * attempt));
      }
    }
  }

  /// The `data` of a GraphQL [query]. Tries 3 times on a 5xx or a network
  /// error; throws on GraphQL errors.
  Future<Map<String, Object?>> graphql(
    String query, [
    Map<String, Object?> variables = const {},
  ]) async {
    for (var attempt = 1; ; attempt++) {
      try {
        final request = await _client.postUrl(
          Uri.parse('https://api.github.com/graphql'),
        );
        request.headers.contentType = ContentType.json;
        if (token != null) {
          request.headers.set('Authorization', 'Bearer $token');
        }
        request.write(jsonEncode({'query': query, 'variables': variables}));
        final response = await request.close();
        final body = await response.transform(utf8.decoder).join();
        if (response.statusCode >= 500 && attempt < 3) {
          await Future<void>.delayed(Duration(seconds: 2 * attempt));
          continue;
        }
        if (response.statusCode != 200) {
          throw _GitHubError('GraphQL: ${response.statusCode} $body');
        }
        final json = jsonDecode(body) as Map<String, Object?>;
        if (json['errors'] != null) {
          throw _GitHubError('GraphQL: ${jsonEncode(json['errors'])}');
        }
        return json['data'] as Map<String, Object?>;
      } on IOException {
        if (attempt == 3) rethrow;
        await Future<void>.delayed(Duration(seconds: 2 * attempt));
      }
    }
  }

  /// DELETE [path]; throws unless GitHub answers 204.
  Future<void> delete(String path) async {
    final request = await _client.deleteUrl(
      Uri.parse('https://api.github.com/$path'),
    );
    request.headers
      ..set('Accept', 'application/vnd.github+json')
      ..set('X-GitHub-Api-Version', '2022-11-28');
    if (token != null) {
      request.headers.set('Authorization', 'Bearer $token');
    }
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode != 204) {
      throw _GitHubError('DELETE $path: ${response.statusCode} $body');
    }
  }

  /// The text of [path] on [ref], null when it does not exist.
  Future<String?> file(String repo, String path, String ref) async {
    final json = await get(
      'repos/$repo/contents/$path?ref=${Uri.encodeQueryComponent(ref)}',
    );
    final content = json?['content'];
    if (content is! String) return null;
    return utf8.decode(base64.decode(content.replaceAll('\n', '')));
  }
}

final class _GitHubError implements Exception {
  _GitHubError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Whether [pubspec] has kiln among its dependencies or dev_dependencies.
bool pubspecUsesKiln(String pubspec) {
  final root = loadYaml(pubspec);
  if (root is! YamlMap) return false;
  return ['dependencies', 'dev_dependencies'].any(
    (key) => root[key] is YamlMap && (root[key] as YamlMap).containsKey('kiln'),
  );
}

/// Whether a workflow uses an action or workflow of telosnex_ci_tools.
bool workflowUsesCiTools(String workflow) => RegExp(
  r'^\s*(-\s+)?uses:\s*Telosnex/telosnex_ci_tools/',
  multiLine: true,
).hasMatch(workflow);

/// The `working-directory` inputs of the calls of telosnex_ci_tools' Kiln
/// workflows in [workflow]: where a repository keeps its Kiln package when
/// not at the root.
Set<String> kilnWorkingDirectories(String workflow) {
  final Object? root;
  try {
    root = loadYaml(workflow);
  } on YamlException {
    return const {};
  }
  final jobs = root is YamlMap ? root['jobs'] : null;
  if (jobs is! YamlMap) return const {};
  return {
    for (final job in jobs.values)
      if (job is YamlMap &&
          job['uses'] is String &&
          RegExp(
            r'^Telosnex/telosnex_ci_tools/\.github/workflows/kiln_',
          ).hasMatch(job['uses'] as String) &&
          job['with'] is YamlMap &&
          (job['with'] as YamlMap)['working-directory'] is String)
        ((job['with'] as YamlMap)['working-directory'] as String).replaceAll(
          RegExp(r'^\./|/$'),
          '',
        ),
  }..remove('');
}

/// The names of the jobs of [workflow] that another job needs (`needs:`).
/// A job's name is its `name:`, or its id when it has none.
Set<String> neededJobNames(String workflow) {
  final Object? root;
  try {
    root = loadYaml(workflow);
  } on YamlException {
    return const {};
  }
  final jobs = root is YamlMap ? root['jobs'] : null;
  if (jobs is! YamlMap) return const {};
  final needed = <Object?>{
    for (final job in jobs.values)
      if (job is YamlMap)
        ...switch (job['needs']) {
          final String id => [id],
          final YamlList ids => ids,
          _ => const [],
        },
  };
  return {
    for (final MapEntry(:key, :value) in jobs.entries)
      if (needed.contains(key))
        switch (value) {
          YamlMap() when value['name'] is String => value['name'] as String,
          _ => key as String,
        },
  };
}

/// Whether the default branch uses Kiln (the root pubspec, or the pubspec
/// in the working-directory of a Kiln workflow call) and CI tools (a
/// workflow).
Future<({bool kiln, bool ciTools})> _adoption(
  GitHubReader github,
  String repo,
  String branch,
) async {
  final list = await github.getJson(
    'repos/$repo/contents/.github/workflows'
    '?ref=${Uri.encodeQueryComponent(branch)}',
  );
  var ciTools = false;
  final kilnDirs = <String>{''};
  for (final entry in (list is List ? list : const []).cast<Map>()) {
    final name = entry['name'] as String;
    if (!name.endsWith('.yml') && !name.endsWith('.yaml')) continue;
    final text = await github.file(repo, '.github/workflows/$name', branch);
    if (text == null) continue;
    if (workflowUsesCiTools(text)) ciTools = true;
    kilnDirs.addAll(kilnWorkingDirectories(text));
  }
  var kiln = false;
  for (final dir in kilnDirs) {
    final path = dir.isEmpty ? 'pubspec.yaml' : '$dir/pubspec.yaml';
    final pubspec = await github.file(repo, path, branch);
    if (pubspec != null && pubspecUsesKiln(pubspec)) {
      kiln = true;
      break;
    }
  }
  return (kiln: kiln, ciTools: ciTools);
}

/// Reads one package: the newest finished run of each workflow and its jobs.
Future<PackageStatus> fetchPackage(
  GitHubReader github,
  DashboardPackage package,
) async {
  final repo = package.repo;
  try {
    final info = await github.get('repos/$repo');
    if (info == null) {
      return PackageStatus(package, '', const {}, error: 'not found');
    }
    final branch = info['default_branch'] as String;
    final adoption = await _adoption(github, repo, branch);
    final runs = <String, DashboardRun>{};
    for (final file in {
      ...package.tests,
      ...package.checks,
      ...package.releases,
    }) {
      final run = await _newestRun(
        github,
        repo,
        file,
        package.releases.contains(file) ? null : branch,
      );
      if (run == null) continue;
      // Setup jobs from the workflow at the run's commit, when it is a test
      // workflow.
      if (!package.tests.contains(file)) {
        runs[file] = run;
        continue;
      }
      final text = await github.file(
        repo,
        '.github/workflows/$file',
        run.sha.isEmpty ? branch : run.sha,
      );
      runs[file] = text == null
          ? run
          : DashboardRun(
              workflowFile: run.workflowFile,
              workflowName: run.workflowName,
              branch: run.branch,
              sha: run.sha,
              event: run.event,
              conclusion: run.conclusion,
              url: run.url,
              finishedAt: run.finishedAt,
              jobs: run.jobs,
              setupJobs: neededJobNames(text),
            );
    }
    return PackageStatus(
      package,
      branch,
      runs,
      usesKiln: adoption.kiln,
      usesCiTools: adoption.ciTools,
    );
  } on Exception catch (error) {
    return PackageStatus(package, '', const {}, error: '$error');
  }
}

/// The newest finished run of [file], skipping cancelled runs (a newer push
/// cancels a run of the same concurrency group) when a newer finished one
/// is in the last 20.
Future<DashboardRun?> _newestRun(
  GitHubReader github,
  String repo,
  String file,
  String? branch,
) async {
  final query = [
    'status=completed',
    'per_page=20',
    'exclude_pull_requests=true',
    if (branch != null) 'branch=${Uri.encodeQueryComponent(branch)}',
  ].join('&');
  final page = await github.get(
    'repos/$repo/actions/workflows/$file/runs?$query',
  );
  final list = (page?['workflow_runs'] as List? ?? const [])
      .cast<Map<String, Object?>>();
  if (list.isEmpty) return null;
  final run = list.firstWhere(
    (run) => run['conclusion'] != 'cancelled',
    orElse: () => list.first,
  );
  final jobs = <DashboardJob>[];
  for (var number = 1; ; number++) {
    final page = await github.get(
      'repos/$repo/actions/runs/${run['id']}/jobs'
      '?filter=latest&per_page=100&page=$number',
    );
    final list = (page?['jobs'] as List? ?? const [])
        .cast<Map<String, Object?>>();
    for (final job in list) {
      jobs.add(
        DashboardJob(
          name: job['name'] as String,
          conclusion: job['conclusion'] as String?,
          url: job['html_url'] as String,
        ),
      );
    }
    if (list.length < 100) break;
  }
  return DashboardRun(
    workflowFile: file,
    workflowName: run['name'] as String? ?? file,
    branch: run['head_branch'] as String? ?? '',
    sha: run['head_sha'] as String? ?? '',
    event: run['event'] as String? ?? '',
    conclusion: run['conclusion'] as String?,
    url: run['html_url'] as String,
    finishedAt: DateTime.parse(
      run['updated_at'] as String? ?? run['created_at'] as String,
    ),
    jobs: jobs,
  );
}
