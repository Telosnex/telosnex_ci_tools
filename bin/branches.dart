/// dart run telosnex_ci_tools:branches [--org Telosnex] [--repo <name>...]
///     [--delete-merged] [--out <file>]
///
/// Lists the branches of every repository of the organization (not
/// archived) other than its default branch:
/// - Merged: every commit is on the default branch, so deleting it loses
///   nothing. --delete-merged deletes these, and only these.
/// - In review: an open pull request comes from it.
/// - Not merged: commits not on the default branch, no open pull request.
///   A squash-merged branch is here too.
/// Not listed: the branches workflows use (a trigger branch in `on: push:
/// branches:` of a workflow on the default branch, such as kiln-release;
/// and outputBranches), and, in a fork, branches whose head is older than
/// the fork: copies of upstream branches.
/// The token: GITHUB_TOKEN or GH_TOKEN, else `gh auth token`.
library;

import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:telosnex_ci_tools/src/branches.dart';
import 'package:telosnex_ci_tools/src/dashboard_fetch.dart';

const _reposQuery = r'''
query($org: String!, $after: String) {
  organization(login: $org) {
    repositories(first: 25, after: $after, orderBy: {field: NAME, direction: ASC}) {
      pageInfo { hasNextPage endCursor }
      nodes {
        name isFork isArchived createdAt defaultBranchRef { name }
        workflows: object(expression: "HEAD:.github/workflows") {
          ... on Tree { entries { object { ... on Blob { text } } } }
        }
      }
    }
  }
}
''';

const _refsQuery = r'''
query($org: String!, $repo: String!, $after: String) {
  repository(owner: $org, name: $repo) {
    refs(refPrefix: "refs/heads/", first: 100, after: $after) {
      pageInfo { hasNextPage endCursor }
      nodes {
        name
        target { ... on Commit { committedDate } }
        associatedPullRequests(states: OPEN, first: 1) { nodes { url } }
      }
    }
  }
}
''';

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption('org', defaultsTo: 'Telosnex')
    ..addMultiOption('repo', help: 'Only these repositories.')
    ..addFlag(
      'delete-merged',
      negatable: false,
      help: 'Delete the merged branches (every commit on the default branch).',
    )
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
      'dart run telosnex_ci_tools:branches [options]\n\n${parser.usage}',
    );
    return;
  }
  final org = args.option('org')!;
  final only = {for (final r in args.multiOption('repo')) r.toLowerCase()};
  final github = await GitHubReader.fromEnvironment();
  try {
    final found = <(Branch, BranchState)>[];
    for (final repo in await _repos(github, org)) {
      final name = repo['name']! as String;
      if (repo['isArchived'] == true) continue;
      if (only.isNotEmpty && !only.contains(name.toLowerCase())) continue;
      final defaultBranch =
          (repo['defaultBranchRef'] as Map<String, Object?>?)?['name']
              as String?;
      if (defaultBranch == null) continue; // Empty repository.
      final triggers = triggerBranches([
        for (final entry
            in ((repo['workflows'] as Map<String, Object?>?)?['entries']
                        as List? ??
                    const [])
                .cast<Map<String, Object?>>())
          if ((entry['object'] as Map<String, Object?>?)?['text']
              case final String text)
            text,
      ]);
      final forkedAt = repo['isFork'] == true
          ? DateTime.parse(repo['createdAt']! as String)
          : null;
      final branches = [
        for (final ref in await _refs(github, org, name))
          if (ref['name'] != defaultBranch) ref,
      ];
      // Compare only the branches that are not settled without it.
      final pending = <Branch>[];
      for (final ref in branches) {
        final committed =
            (ref['target'] as Map<String, Object?>?)?['committedDate']
                as String?;
        if (committed == null) continue; // A tag-like ref: not a commit.
        final pr =
            ((ref['associatedPullRequests'] as Map<String, Object?>)['nodes']
                    as List)
                .cast<Map<String, Object?>>();
        final branch = Branch(
          repo: name,
          name: ref['name']! as String,
          committedAt: DateTime.parse(committed),
          pullRequest: pr.isEmpty ? null : pr.first['url'] as String?,
        );
        final state = classify(branch, forkedAt: forkedAt, triggers: triggers);
        if (state == BranchState.notMerged) {
          pending.add(branch);
        } else {
          found.add((branch, state));
        }
      }
      for (final branch in await _compare(
        github,
        org,
        name,
        defaultBranch,
        pending,
      )) {
        found.add((
          branch,
          classify(branch, forkedAt: forkedAt, triggers: triggers),
        ));
      }
    }

    final report = renderBranches(org, found, DateTime.now().toUtc());
    if (args.option('out') case final out?) {
      File(out).writeAsStringSync(report);
    } else {
      stdout.write(report);
    }

    if (args.flag('delete-merged')) {
      final merged = [
        for (final (branch, state) in found)
          if (state == BranchState.merged) branch,
      ];
      stdout.writeln();
      for (final b in merged) {
        await github.delete(
          'repos/$org/${b.repo}/git/refs/heads/'
          '${b.name.split('/').map(Uri.encodeComponent).join('/')}',
        );
        stdout.writeln('Deleted ${b.repo} ${b.name}');
      }
      stdout.writeln('Deleted ${merged.length} merged branches.');
    }
  } finally {
    github.close();
  }
}

Future<List<Map<String, Object?>>> _repos(
  GitHubReader github,
  String org,
) async {
  final repos = <Map<String, Object?>>[];
  String? after;
  do {
    final data = await github.graphql(_reposQuery, {
      'org': org,
      'after': after,
    });
    final page =
        (data['organization']! as Map<String, Object?>)['repositories']!
            as Map<String, Object?>;
    repos.addAll((page['nodes']! as List).cast<Map<String, Object?>>());
    final info = page['pageInfo']! as Map<String, Object?>;
    after = info['hasNextPage'] == true ? info['endCursor'] as String? : null;
  } while (after != null);
  return repos;
}

Future<List<Map<String, Object?>>> _refs(
  GitHubReader github,
  String org,
  String repo,
) async {
  final refs = <Map<String, Object?>>[];
  String? after;
  do {
    final data = await github.graphql(_refsQuery, {
      'org': org,
      'repo': repo,
      'after': after,
    });
    final page =
        (data['repository']! as Map<String, Object?>)['refs']!
            as Map<String, Object?>;
    refs.addAll((page['nodes']! as List).cast<Map<String, Object?>>());
    final info = page['pageInfo']! as Map<String, Object?>;
    after = info['hasNextPage'] == true ? info['endCursor'] as String? : null;
  } while (after != null);
  return refs;
}

/// [branches] with [Branch.onlyHere]: the commits on each that are not on
/// [defaultBranch]. 50 refs per query, as aliases.
Future<List<Branch>> _compare(
  GitHubReader github,
  String org,
  String repo,
  String defaultBranch,
  List<Branch> branches,
) async {
  final result = <Branch>[];
  for (var start = 0; start < branches.length; start += 50) {
    final batch = branches.skip(start).take(50).toList();
    // Base: the branch; head: the default branch. behindBy is then the
    // number of commits on the branch that the default branch lacks.
    final fields = [
      for (final (i, b) in batch.indexed)
        'b$i: ref(qualifiedName: ${jsonEncode('refs/heads/${b.name}')}) '
            '{ compare(headRef: ${jsonEncode(defaultBranch)}) { behindBy } }',
    ];
    final data = await github.graphql(
      'query { repository(owner: ${jsonEncode(org)}, name: '
      '${jsonEncode(repo)}) { ${fields.join(' ')} } }',
    );
    final repository = data['repository']! as Map<String, Object?>;
    for (final (i, b) in batch.indexed) {
      final ref = repository['b$i'] as Map<String, Object?>?;
      final compare = ref?['compare'] as Map<String, Object?>?;
      result.add(
        Branch(
          repo: b.repo,
          name: b.name,
          committedAt: b.committedAt,
          pullRequest: b.pullRequest,
          onlyHere: compare?['behindBy'] as int?,
        ),
      );
    }
  }
  return result;
}
