import 'dart:convert';
import 'dart:io';

import 'package:yaml/yaml.dart';

import 'dashboard.dart';

/// Reads dashboard.yaml.
List<DashboardPackage> readDashboardConfig(String yaml) {
  final root = loadYaml(yaml);
  final packages = root is YamlMap ? root['packages'] : null;
  if (packages is! YamlList) {
    throw const FormatException('dashboard.yaml: no packages list.');
  }
  List<String>? files(YamlMap entry, String key) {
    final value = entry[key];
    if (value == null) return null;
    if (value is! YamlList) {
      throw FormatException('dashboard.yaml: $key must be a list.');
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
        throw FormatException('dashboard.yaml: $entry has no repo.'),
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
  Future<Map<String, Object?>?> get(String path) async {
    final request = await _client.getUrl(
      Uri.parse('https://api.github.com/$path'),
    );
    request.headers
      ..set('Accept', 'application/vnd.github+json')
      ..set('X-GitHub-Api-Version', '2022-11-28');
    if (token != null) request.headers.set('Authorization', 'Bearer $token');
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode == 404) return null;
    if (response.statusCode != 200) {
      throw HttpException('GET $path: ${response.statusCode} $body');
    }
    return jsonDecode(body) as Map<String, Object?>;
  }
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
      if (run != null) runs[file] = run;
    }
    return PackageStatus(package, branch, runs);
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
