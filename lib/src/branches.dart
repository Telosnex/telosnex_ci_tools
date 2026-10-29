/// The branches of an organization's repositories other than the default
/// branch, sorted by whether they can go (bin/branches.dart).
library;

import 'package:yaml/yaml.dart';

/// Branches that workflows write to (their output), kept in every
/// repository.
const outputBranches = {
  // telosnex_ci_tools: the Dashboard workflow commits the page there.
  'dashboard',
  'gh-pages',
};

/// The branch names, without wildcards, that start a workflow on push
/// (`on: push: branches:`): release triggers such as kiln-release. Branches
/// that match only a pattern (ci/**) are not trigger branches.
Set<String> triggerBranches(Iterable<String> workflowTexts) {
  final names = <String>{};
  for (final text in workflowTexts) {
    final Object? doc;
    try {
      doc = loadYaml(text);
    } on YamlException {
      continue;
    }
    if (doc is! YamlMap) continue;
    final on = doc['on'] ?? doc[true];
    if (on is! YamlMap) continue;
    final push = on['push'];
    if (push is! YamlMap) continue;
    final branches = push['branches'];
    for (final b in branches is YamlList ? branches : [branches]) {
      if (b is String && !b.contains('*') && !b.startsWith('!')) names.add(b);
    }
  }
  return names;
}

/// What to do with a branch.
enum BranchState {
  /// Every commit is on the default branch: safe to delete.
  merged,

  /// An open pull request comes from it.
  inReview,

  /// Commits that are not on the default branch, and no open pull request.
  notMerged,

  /// In [outputBranches], or a trigger branch of a workflow.
  kept,

  /// In a fork, with a head older than the fork: a copy of an upstream
  /// branch, not ours.
  upstream,
}

final class Branch {
  const Branch({
    required this.repo,
    required this.name,
    required this.committedAt,
    this.onlyHere,
    this.pullRequest,
  });

  final String repo;
  final String name;

  /// Of the head commit.
  final DateTime committedAt;

  /// Commits on this branch that are not on the default branch. Null when
  /// GitHub could not compare them (no common history).
  final int? onlyHere;

  /// The URL of an open pull request from this branch.
  final String? pullRequest;
}

/// [forkedAt]: when the repository was created, for a fork; null for a
/// repository that is not a fork.
/// [triggers]: the repository's [triggerBranches].
BranchState classify(
  Branch branch, {
  DateTime? forkedAt,
  Set<String> triggers = const {},
}) {
  if (outputBranches.contains(branch.name) || triggers.contains(branch.name)) {
    return BranchState.kept;
  }
  if (branch.pullRequest != null) return BranchState.inReview;
  if (forkedAt != null && branch.committedAt.isBefore(forkedAt)) {
    return BranchState.upstream;
  }
  if (branch.onlyHere == 0) return BranchState.merged;
  return BranchState.notMerged;
}

String _age(DateTime at, DateTime now) {
  final days = now.difference(at).inDays;
  return days == 0 ? 'today' : '${days}d';
}

/// Markdown: merged, in review, not merged; then counts of the others.
String renderBranches(
  String org,
  List<(Branch, BranchState)> branches,
  DateTime now,
) {
  List<Branch> inState(BranchState state) => [
    for (final (branch, s) in branches)
      if (s == state) branch,
  ]..sort((a, b) => '${a.repo}/${a.name}'.compareTo('${b.repo}/${b.name}'));
  String link(Branch b) =>
      '[${b.name}](https://github.com/$org/${b.repo}/tree/${b.name})';

  final out = StringBuffer('# Branches of $org\n');
  void table(
    String title,
    String note,
    List<Branch> list,
    String Function(Branch) extra,
    String extraHeader,
  ) {
    out
      ..writeln()
      ..writeln('## $title (${list.length})')
      ..writeln()
      ..writeln(note);
    if (list.isEmpty) return;
    out
      ..writeln()
      ..writeln('| Repository | Branch | Last commit | $extraHeader |')
      ..writeln('|---|---|---|---|');
    for (final b in list) {
      out.writeln(
        '| ${b.repo} | ${link(b)} | ${_age(b.committedAt, now)} | ${extra(b)} |',
      );
    }
  }

  table(
    'Merged',
    'Every commit is on the default branch: safe to delete '
        '(`--delete-merged`).',
    inState(BranchState.merged),
    (_) => '',
    '',
  );
  table(
    'In review',
    'An open pull request comes from the branch.',
    inState(BranchState.inReview),
    (b) => b.pullRequest!,
    'Pull request',
  );
  table(
    'Not merged',
    'Commits that are not on the default branch, and no open pull request. '
        'A squash-merged branch is here too: check before deleting.',
    inState(BranchState.notMerged),
    (b) => b.onlyHere == null ? 'no common history' : '${b.onlyHere} commits',
    'Not on the default branch',
  );
  final kept = inState(BranchState.kept);
  final upstream = inState(BranchState.upstream);
  out
    ..writeln()
    ..writeln(
      'Not listed: ${kept.length} kept branches (workflow triggers such as '
      'kiln-release, and ${outputBranches.join(', ')}), '
      'and ${upstream.length} upstream branches in '
      '${{for (final b in upstream) b.repo}.length} forks (heads older than '
      'the fork).',
    );
  return out.toString();
}
