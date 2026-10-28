/// dart run telosnex_ci_tools:repos [--org Telosnex] [--app Telosnex/telosnex]
///     [--app-dir <checkout>] [--forks-only] [--json] [--out <file>]
///
/// Sorts every repository of the organization but the app (with
/// --forks-only, its forks) into:
/// - Live: a workflow on the default branch uses telosnex_ci_tools;
/// - Missing CI: the app depends on it (a git dependency in a pubspec.yaml,
///   pubspec_overrides.yaml or pubspec.lock of the app's default branch),
///   without telosnex_ci_tools;
/// - Unused: neither;
/// - Skipped: listed in status/repos.yaml (or --skip-file) with a reason.
///   A skipped repository the app uses, or that uses telosnex_ci_tools, is
///   reported as a warning: the skip is out of date.
/// A repository that is not a fork is also used when the app uses its
/// package (the name in its root pubspec.yaml) from pub.dev.
/// Also lists, per repository, the workflows (of the app, and of every
/// repository of the organization) that use it as an action.
/// Prints Markdown (or JSON with --json), or writes it to --out.
///
/// The app's files: from --app-dir (a checkout; reads its origin's default
/// branch after a fetch), else a blobless clone into a temporary directory.
/// The token: GITHUB_TOKEN or GH_TOKEN, else `gh auth token`; it needs read
/// access to the app.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:args/args.dart';
import 'package:telosnex_ci_tools/src/dashboard_fetch.dart';
import 'package:telosnex_ci_tools/src/repos.dart';

const _reposQuery = r'''
query($org: String!, $after: String) {
  organization(login: $org) {
    repositories(first: 25, after: $after, orderBy: {field: NAME, direction: ASC}) {
      pageInfo { hasNextPage endCursor }
      nodes {
        name
        isFork
        isArchived
        pushedAt
        parent { nameWithOwner }
        pubspec: object(expression: "HEAD:pubspec.yaml") { ... on Blob { text } }
        workflows: object(expression: "HEAD:.github/workflows") {
          ... on Tree { entries { name object { ... on Blob { text } } } }
        }
      }
    }
  }
}
''';

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption('org', defaultsTo: 'Telosnex')
    ..addOption('app', defaultsTo: 'Telosnex/telosnex')
    ..addOption('app-dir', help: 'A checkout of the app; else a clone.')
    ..addFlag('forks-only', negatable: false, help: 'Only forks.')
    ..addOption(
      'skip-file',
      help:
          'Repositories to skip, with reasons. Default: status/repos.yaml '
          'of this package.',
    )
    ..addFlag('json', negatable: false)
    ..addOption('out')
    ..addFlag('help', abbr: 'h', negatable: false);
  final ArgResults args;
  try {
    args = parser.parse(arguments);
  } on FormatException catch (e) {
    stderr.writeln('${e.message}\n${parser.usage}');
    exit(2);
  }
  if (args.flag('help')) {
    stdout.writeln(
      'dart run telosnex_ci_tools:repos [options]\n\n${parser.usage}',
    );
    return;
  }
  final org = args.option('org')!;
  final app = args.option('app')!;
  final skipPath =
      args.option('skip-file') ??
      (await Isolate.resolvePackageUri(
        Uri.parse('package:telosnex_ci_tools/'),
      ))!.resolve('../status/repos.yaml').toFilePath();
  final Map<String, String> skips;
  try {
    final file = File(skipPath);
    skips = file.existsSync() ? parseSkips(file.readAsStringSync()) : const {};
  } on FormatException catch (e) {
    stderr.writeln('$skipPath: ${e.message}');
    exit(2);
  }
  final github = await GitHubReader.fromEnvironment();
  try {
    final (appRef, references, appWorkflows, hosted) = await _appReferences(
      app,
      args.option('app-dir'),
      github.token,
    );
    final (repos, orgWorkflows) = await _orgRepos(github, org);
    final appName = app.split('/').last.toLowerCase();
    final actionUsers = <String, Set<String>>{};
    for (final (user, texts) in [
      (app, appWorkflows),
      for (final MapEntry(:key, :value) in orgWorkflows.entries)
        if (key.toLowerCase() != appName) ('$org/$key', value),
    ]) {
      for (final text in texts) {
        for (final repo in actionRepos(text, org)) {
          if ('$org/$repo'.toLowerCase() == user.toLowerCase()) continue;
          (actionUsers[repo] ??= {}).add(user.split('/').last);
        }
      }
    }
    final byName = {for (final r in repos) r.name.toLowerCase(): r};

    // References by URL: a renamed repository answers at its old name.
    final found = <String, List<RepoReference>>{};
    final resolved = <String, String?>{};
    for (final reference in references) {
      if (reference.owner.toLowerCase() != org.toLowerCase()) continue;
      var name = reference.repo.toLowerCase();
      if (!byName.containsKey(name)) {
        name = resolved[name] ??= await _currentName(
          github,
          org,
          reference.repo,
        );
        if (name.isEmpty) {
          stderr.writeln(
            'Warning: ${reference.file} (${reference.package}) refers to '
            '${reference.owner}/${reference.repo}, which does not exist.',
          );
          continue;
        }
      }
      (found[name] ??= []).add(reference);
    }
    // Own packages from pub.dev (not forks: a fork has the name of the
    // package on pub.dev the app may use instead).
    for (final repo in repos) {
      final package = repo.packageName;
      if (repo.isFork || package == null) continue;
      for (final MapEntry(key: lock, value: names) in hosted.entries) {
        if (!names.contains(package)) continue;
        (found[repo.name.toLowerCase()] ??= []).add(
          RepoReference(
            owner: org,
            repo: repo.name,
            file: lock,
            package: package,
            hosted: true,
          ),
        );
      }
    }

    for (final name in skips.keys) {
      if (!byName.containsKey(name)) {
        stderr.writeln(
          'Warning: $skipPath skips $name, not a repository of $org.',
        );
      }
    }
    final report = [
      for (final repo in repos)
        // The app is not a dependency of itself.
        if (repo.name.toLowerCase() != appName &&
            (repo.isFork || !args.flag('forks-only')))
          repo.withUses(
            found[repo.name.toLowerCase()] ?? const [],
            actionUsers[repo.name.toLowerCase()] ?? const {},
            skipReason: skips[repo.name.toLowerCase()],
          ),
    ];
    for (final repo in report) {
      if (repo.skipReason != null && (repo.used || repo.usesCiTools)) {
        stderr.writeln(
          'Warning: $skipPath skips ${repo.name}, but '
          '${repo.used ? '$app depends on it' : 'it uses telosnex_ci_tools'}.',
        );
      }
    }
    final text = args.flag('json')
        ? '${const JsonEncoder.withIndent(' ').convert({
            'org': org,
            'app': app,
            'appRef': appRef,
            'repositories': [for (final r in report) r.toJson()],
          })}\n'
        : renderForks(report, org: org, app: app, appRef: appRef);
    final out = args.option('out');
    if (out == null) {
      stdout.write(text);
    } else {
      File(out).writeAsStringSync(text);
      final counts = [
        for (final c in ForkCategory.values)
          '${c.title} ${report.where((r) => r.category == c).length}',
      ].join(', ');
      stdout.writeln('Wrote $out: $counts.');
    }
  } finally {
    github.close();
  }
}

/// The current name of [org]/[repo] in lowercase, after a rename; empty
/// when it does not exist.
Future<String> _currentName(
  GitHubReader github,
  String org,
  String repo,
) async {
  final json = await github.get('repos/$org/$repo');
  final fullName = json?['full_name'];
  if (fullName is! String) return '';
  final parts = fullName.split('/');
  if (parts.first.toLowerCase() != org.toLowerCase()) return '';
  return parts.last.toLowerCase();
}

/// The repositories, and the workflow texts of each by name.
Future<(List<OrgRepo>, Map<String, List<String>>)> _orgRepos(
  GitHubReader github,
  String org,
) async {
  final repos = <OrgRepo>[];
  final workflows = <String, List<String>>{};
  String? after;
  do {
    final data = await github.graphql(_reposQuery, {
      'org': org,
      'after': after,
    });
    final connection =
        (data['organization'] as Map)['repositories'] as Map<String, Object?>;
    for (final node in (connection['nodes'] as List).cast<Map>()) {
      final entries = (node['workflows'] as Map?)?['entries'] as List?;
      final texts = [
        for (final entry in (entries ?? const []).cast<Map>())
          if (((entry['name'] as String).endsWith('.yml') ||
                  (entry['name'] as String).endsWith('.yaml')) &&
              (entry['object'] as Map?)?['text'] is String)
            (entry['object'] as Map)['text'] as String,
      ];
      workflows[node['name'] as String] = texts;
      final usesCiTools = texts.any(workflowUsesCiTools);
      final pushedAt = node['pushedAt'];
      final pubspec = (node['pubspec'] as Map?)?['text'];
      repos.add(
        OrgRepo(
          name: node['name'] as String,
          isFork: node['isFork'] as bool,
          isArchived: node['isArchived'] as bool,
          usesCiTools: usesCiTools,
          parent: (node['parent'] as Map?)?['nameWithOwner'] as String?,
          pushedAt: pushedAt is String ? DateTime.parse(pushedAt) : null,
          packageName: pubspec is String ? pubspecName(pubspec) : null,
        ),
      );
    }
    final page = connection['pageInfo'] as Map;
    after = page['hasNextPage'] == true ? page['endCursor'] as String : null;
  } while (after != null);
  return (repos, workflows);
}

/// The ref read, every git dependency in the app's dependency files, the
/// texts of its workflows, and the hosted packages of each pubspec.lock.
Future<(String, List<RepoReference>, List<String>, Map<String, Set<String>>)>
_appReferences(String app, String? appDir, String? token) async {
  final auth = token == null
      ? const <String>[]
      : [
          '-c',
          'http.https://github.com/.extraheader=AUTHORIZATION: basic '
              '${base64.encode(utf8.encode('x-access-token:$token'))}',
        ];
  Directory? temp;
  final String dir;
  final String ref;
  if (appDir != null) {
    dir = appDir;
    await _git(dir, [...auth, 'fetch', '-q', 'origin']);
    // origin/HEAD is set by clone; set it when a checkout lacks it.
    await _git(dir, [...auth, 'remote', 'set-head', 'origin', '--auto']);
    ref = 'origin/HEAD';
  } else {
    temp = Directory.systemTemp.createTempSync('repos_app_');
    dir = temp.path;
    await _git(dir, [
      ...auth,
      'clone',
      '-q',
      '--depth',
      '1',
      '--filter=blob:none',
      '--no-checkout',
      'https://github.com/$app.git',
      '.',
    ]);
    ref = 'HEAD';
  }
  try {
    final commit = (await _git(dir, ['rev-parse', '--short', ref])).trim();
    final branch = (await _git(dir, [
      'rev-parse',
      '--abbrev-ref',
      ref == 'HEAD' ? 'HEAD' : 'origin/HEAD',
    ])).trim().replaceFirst('origin/', '');
    final all = (await _git(dir, [
      'ls-tree',
      '-r',
      '--name-only',
      ref,
    ])).split('\n');
    final references = <RepoReference>[];
    final hosted = <String, Set<String>>{};
    for (final path in all.where(isDependencyFile)) {
      final text = await _git(dir, [...auth, 'show', '$ref:$path']);
      references.addAll(referencesIn(path, text));
      if (path.endsWith('pubspec.lock')) hosted[path] = hostedPackagesIn(text);
    }
    final workflows = [
      for (final path in all)
        if (RegExp(r'^\.github/workflows/[^/]+\.ya?ml$').hasMatch(path))
          await _git(dir, [...auth, 'show', '$ref:$path']),
    ];
    return ('$branch@$commit', references, workflows, hosted);
  } finally {
    temp?.deleteSync(recursive: true);
  }
}

Future<String> _git(String dir, List<String> args) async {
  final result = await Process.run('git', args, workingDirectory: dir);
  if (result.exitCode != 0) {
    final shown = args.where((a) => !a.contains('AUTHORIZATION')).join(' ');
    throw ProcessException('git', [shown], '${result.stderr}'.trim());
  }
  return result.stdout as String;
}
