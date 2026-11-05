import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'package:yaml/yaml.dart';

import 'dashboard.dart';
import 'upstream.dart' show upstreamNote;

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
          // The upstream watch shows wherever a package has one.
          checks: {
            ...files(entry, 'checks') ?? const ['kiln_check.yml'],
            upstreamWatchWorkflow,
          }.toList(),
          releases: files(entry, 'releases') ?? const ['kiln_release.yml'],
        )
      else
        throw FormatException('packages.yaml: $entry has no repo.'),
  ];
}

/// Added to the checks of every package; dropped where it is absent.
const upstreamWatchWorkflow = 'upstream_watch.yml';

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
Future<({bool kiln, bool ciTools, Set<String> workflows})> _adoption(
  GitHubReader github,
  String repo,
  String branch,
) async {
  final list = await github.getJson(
    'repos/$repo/contents/.github/workflows'
    '?ref=${Uri.encodeQueryComponent(branch)}',
  );
  var ciTools = false;
  final workflows = <String>{};
  final kilnDirs = <String>{''};
  for (final entry in (list is List ? list : const []).cast<Map>()) {
    final name = entry['name'] as String;
    if (!name.endsWith('.yml') && !name.endsWith('.yaml')) continue;
    workflows.add(name);
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
  return (kiln: kiln, ciTools: ciTools, workflows: workflows);
}

/// The `owner/name` of a GitHub repository URL, or null.
String? gitHubRepoOf(String? url) {
  final match = RegExp(
    r'github\.com[/:]([^/\s]+)/([^/#?\s]+)',
  ).firstMatch(url ?? '');
  if (match == null) return null;
  final name = match.group(2)!;
  return '${match.group(1)}/'
      '${name.endsWith('.git') ? name.substring(0, name.length - 4) : name}';
}

/// The packages of [publisher] on pub.dev, each at its newest version.
Future<List<PubPackage>> fetchPublisherPackages(String publisher) async {
  final client = HttpClient()..userAgent = 'telosnex_ci_tools-dashboard';
  Future<Map<String, Object?>> get(Uri uri) async {
    for (var attempt = 1; ; attempt++) {
      try {
        final response = await (await client.getUrl(uri)).close();
        final body = await response.transform(utf8.decoder).join();
        if (response.statusCode == 200) {
          return jsonDecode(body) as Map<String, Object?>;
        }
        if (response.statusCode < 500 || attempt == 3) {
          throw HttpException('GET $uri: ${response.statusCode}', uri: uri);
        }
      } on SocketException {
        if (attempt == 3) rethrow;
      }
      await Future<void>.delayed(Duration(seconds: 2 * attempt));
    }
  }

  try {
    final names = <String>[];
    Uri? page = Uri.https('pub.dev', '/api/search', {
      'q': 'publisher:$publisher',
    });
    while (page != null) {
      final result = await get(page);
      names.addAll([
        for (final p in result['packages'] as List? ?? const [])
          (p as Map)['package'] as String,
      ]);
      final next = result['next'] as String?;
      page = next == null ? null : Uri.parse(next);
    }
    return await Future.wait([
      for (final name in names)
        get(Uri.https('pub.dev', '/api/packages/$name')).then((info) {
          final latest = info['latest'] as Map;
          final pubspec = latest['pubspec'] as Map;
          return PubPackage(
            name: name,
            version: latest['version'] as String,
            published: DateTime.parse(latest['published'] as String),
            repo: gitHubRepoOf(
              (pubspec['repository'] ?? pubspec['homepage']) as String?,
            ),
            archiveUrl: latest['archive_url'] as String?,
          );
        }),
    ]);
  } finally {
    client.close();
  }
}

/// The regular files of a .tar.gz, by path.
Map<String, Uint8List> readTarGz(List<int> bytes) {
  final tar = Uint8List.fromList(gzip.decode(bytes));
  String text(int start, int length) {
    var end = start;
    while (end < start + length && tar[end] != 0) {
      end++;
    }
    return utf8.decode(tar.sublist(start, end), allowMalformed: true);
  }

  int octal(int start, int length) {
    final value = text(start, length).trim();
    return value.isEmpty ? 0 : int.parse(value, radix: 8);
  }

  final files = <String, Uint8List>{};
  String? longName;
  var offset = 0;
  while (offset + 512 <= tar.length && tar[offset] != 0) {
    final size = octal(offset + 124, 12);
    final type = String.fromCharCode(tar[offset + 156]);
    final body = tar.sublist(offset + 512, offset + 512 + size);
    var name = text(offset, 100);
    final prefix = text(offset + 345, 155);
    if (prefix.isNotEmpty) name = '$prefix/$name';
    if (type == 'L') {
      longName = utf8.decode(body).replaceAll('\x00', '');
    } else if (type == 'x') {
      // PAX: "<length> path=<name>\n" records.
      final path = RegExp(
        r'\d+ path=([^\n]*)\n',
      ).firstMatch(utf8.decode(body, allowMalformed: true));
      if (path != null) longName = path.group(1);
    } else {
      if (type == '0' || type == '\x00') {
        final path = longName ?? name;
        files[path.startsWith('./') ? path.substring(2) : path] = body;
      }
      longName = null;
    }
    offset += 512 + (size + 511) ~/ 512 * 512;
  }
  return files;
}

/// The git blob hash of [bytes].
String gitBlobHash(List<int> bytes) => sha1.convert([
  ...utf8.encode('blob ${bytes.length}\x00'),
  ...bytes,
]).toString();

/// How [files] (a published version, by path and git blob hash) differs from
/// a repository's [tree] (`git/trees?recursive=1` entries). The package's
/// directory is the one with a pubspec.yaml that matches the most files.
/// Paths under a submodule or symlink are not compared.
PubDrift comparePublished(
  Map<String, String> files,
  List<Map<String, Object?>> tree,
  String branch,
) {
  final blobs = <String, String>{};
  final opaque = <String>[];
  for (final entry in tree) {
    final path = entry['path'] as String;
    if (entry['type'] == 'commit' || entry['mode'] == '120000') {
      opaque.add(path);
    } else if (entry['type'] == 'blob') {
      blobs[path] = entry['sha'] as String;
    }
  }
  String dirOf(String path) {
    final slash = path.lastIndexOf('/');
    return slash < 0 ? '' : path.substring(0, slash);
  }

  String prefix(String directory) => directory.isEmpty ? '' : '$directory/';
  final candidates = [
    for (final path in blobs.keys)
      if (path == 'pubspec.yaml' || path.endsWith('/pubspec.yaml')) dirOf(path),
  ];
  int score(String directory) => files.entries
      .where((f) => blobs['${prefix(directory)}${f.key}'] == f.value)
      .length;
  var directory = '';
  var best = -1;
  for (final candidate in candidates) {
    final s = score(candidate);
    if (s > best) (directory, best) = (candidate, s);
  }
  final at = prefix(directory);
  bool isOpaque(String path) =>
      opaque.any((o) => path == o || path.startsWith('$o/'));
  final nested = [
    for (final c in candidates)
      if (c != directory && c.startsWith(at)) '$c/',
  ];
  final changed = <String>[];
  final onlyPublished = <String>[];
  for (final MapEntry(key: path, value: hash) in files.entries) {
    final inTree = blobs['$at$path'];
    if (inTree == null) {
      if (!isOpaque('$at$path')) onlyPublished.add(path);
    } else if (inTree != hash) {
      changed.add(path);
    }
  }
  final added = [
    for (final path in blobs.keys)
      if (path.startsWith(at))
        if (path.substring(at.length) case final relative
            when RegExp(r'^(lib|bin|hook)/').hasMatch(relative) &&
                !files.containsKey(relative) &&
                !relative.split('/').any((s) => s.startsWith('.')) &&
                !nested.any(path.startsWith))
          relative,
  ];
  return PubDrift(
    branch: branch,
    directory: directory,
    changed: changed..sort(),
    added: added..sort(),
    onlyPublished: onlyPublished..sort(),
  );
}

/// [pub] with how [repo]'s [branch] differs from its newest version.
Future<PubPackage> fetchPubDrift(
  GitHubReader github,
  PubPackage pub,
  String repo,
  String branch,
) async {
  final url = pub.archiveUrl;
  if (url == null) return pub.withDrift(null, 'no archive');
  try {
    final client = HttpClient()..userAgent = 'telosnex_ci_tools-dashboard';
    final List<int> bytes;
    try {
      final response = await (await client.getUrl(Uri.parse(url))).close();
      if (response.statusCode != 200) {
        return pub.withDrift(null, 'archive: ${response.statusCode}');
      }
      bytes = [for (final chunk in await response.toList()) ...chunk];
    } finally {
      client.close();
    }
    final files = {
      for (final MapEntry(:key, :value) in readTarGz(bytes).entries)
        key: gitBlobHash(value),
    };
    final tree = await github.get(
      'repos/$repo/git/trees/${Uri.encodeComponent(branch)}?recursive=1',
    );
    if (tree == null) return pub.withDrift(null, 'no $branch tree');
    if (tree['truncated'] == true) {
      return pub.withDrift(null, 'repository too large to compare');
    }
    return pub.withDrift(
      comparePublished(
        files,
        (tree['tree'] as List).cast<Map<String, Object?>>(),
        branch,
      ),
    );
  } on Object catch (error) {
    return pub.withDrift(null, '$error'.split('\n').first);
  }
}

/// Reads one package: the newest finished run of each workflow and its jobs.
Future<PackageStatus> fetchPackage(
  GitHubReader github,
  DashboardPackage listed,
) async {
  var package = listed;
  final repo = package.repo;
  try {
    final info = await github.get('repos/$repo');
    if (info == null) {
      return PackageStatus(package, '', const {}, error: 'not found');
    }
    final branch = info['default_branch'] as String;
    final adoption = await _adoption(github, repo, branch);
    // A check added to every package shows only where the package has it.
    if (!adoption.workflows.contains(upstreamWatchWorkflow)) {
      package = package.withoutCheck(upstreamWatchWorkflow);
    }
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
      if (file == upstreamWatchWorkflow && run.conclusion == 'failure') {
        runs[file] = run.withNotes(await _upstreamNotes(github, repo, run));
        continue;
      }
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
      currentRepo: info['full_name'] as String?,
    );
  } on Exception catch (error) {
    return PackageStatus(package, '', const {}, error: '$error');
  }
}

/// The newest finished run of [file], skipping cancelled runs (a newer push
/// cancels a run of the same concurrency group) when a newer finished one
/// is in the last 20.
///
/// Filters on `status` here, not with the API's `status=completed`, which
/// can leave out finished runs: on 2026-11-04 it omitted a
/// workflow_dispatch run of fonnx's upstream watch hours after it finished,
/// so the dashboard showed the older failure.
Future<DashboardRun?> _newestRun(
  GitHubReader github,
  String repo,
  String file,
  String? branch,
) async {
  final query = [
    'per_page=20',
    'exclude_pull_requests=true',
    if (branch != null) 'branch=${Uri.encodeQueryComponent(branch)}',
  ].join('&');
  final page = await github.get(
    'repos/$repo/actions/workflows/$file/runs?$query',
  );
  final list = (page?['workflow_runs'] as List? ?? const [])
      .cast<Map<String, Object?>>()
      .where((run) => run['status'] == 'completed')
      .toList();
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

/// The updates and errors that a failed upstream watch run reported, from
/// the annotations of its failed jobs.
Future<List<String>> _upstreamNotes(
  GitHubReader github,
  String repo,
  DashboardRun run,
) async {
  final notes = <String>[];
  for (final job in run.jobs) {
    if (job.conclusion != 'failure') continue;
    final id = Uri.parse(job.url).pathSegments.last;
    final list =
        await github.getJson(
              'repos/$repo/check-runs/$id/annotations?per_page=100',
            )
            as List?;
    for (final a in (list ?? const []).cast<Map<String, Object?>>()) {
      final note = upstreamNote(
        a['title'] as String? ?? '',
        a['message'] as String? ?? '',
      );
      if (note != null) notes.add(note);
    }
  }
  // GitHub lists the annotations newest first.
  return notes.reversed.toList();
}
