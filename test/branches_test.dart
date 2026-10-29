import 'package:telosnex_ci_tools/src/branches.dart';
import 'package:test/test.dart';

void main() {
  final forked = DateTime.utc(2026, 6);
  Branch branch(String name, {DateTime? at, int? onlyHere = 0, String? pr}) =>
      Branch(
        repo: 'r',
        name: name,
        committedAt: at ?? DateTime.utc(2026, 10),
        onlyHere: onlyHere,
        pullRequest: pr,
      );

  group('classify', () {
    test('merged: no commit off the default branch', () {
      expect(classify(branch('ci/x')), BranchState.merged);
    });
    test('not merged: commits off the default branch, or no common '
        'history', () {
      expect(classify(branch('fix/x', onlyHere: 3)), BranchState.notMerged);
      expect(classify(branch('fix/x', onlyHere: null)), BranchState.notMerged);
    });
    test('an open pull request wins over merged', () {
      expect(classify(branch('ci/x', pr: 'u')), BranchState.inReview);
    });
    test('kept: output branches and trigger branches', () {
      expect(classify(branch('dashboard')), BranchState.kept);
      expect(
        classify(
          branch('kiln-release', onlyHere: 4),
          triggers: {'kiln-release'},
        ),
        BranchState.kept,
      );
    });
    test('upstream: in a fork, a head older than the fork', () {
      expect(
        classify(
          branch('beta', at: DateTime.utc(2025), onlyHere: 9),
          forkedAt: forked,
        ),
        BranchState.upstream,
      );
      // Not a fork: listed.
      expect(
        classify(branch('beta', at: DateTime.utc(2025), onlyHere: 9)),
        BranchState.notMerged,
      );
      // Ours, after the fork.
      expect(classify(branch('fix/x'), forkedAt: forked), BranchState.merged);
    });
  });

  test('triggerBranches: exact names in on.push.branches only', () {
    expect(
      triggerBranches([
        '''
on:
  push:
    branches: [main, 'ci/**', kiln-release, '!skip']
''',
        '''
on:
  push:
    branches: wpe-sdk-release
  workflow_dispatch:
''',
        'on: [push, pull_request]',
        'on:\n  pull_request:\n    branches: [pr-only]',
        ': not yaml: [',
      ]),
      {'main', 'kiln-release', 'wpe-sdk-release'},
    );
  });

  test('renderBranches: sections and the not-listed line', () {
    final now = DateTime.utc(2026, 10, 30);
    final md = renderBranches('O', [
      (branch('ci/a'), BranchState.merged),
      (branch('fix/b', onlyHere: 2), BranchState.notMerged),
      (branch('f/c', pr: 'https://x/pull/1'), BranchState.inReview),
      (branch('kiln-release'), BranchState.kept),
      (branch('old', at: DateTime.utc(2025)), BranchState.upstream),
    ], now);
    expect(md, contains('## Merged (1)'));
    expect(
      md,
      contains('| r | [ci/a](https://github.com/O/r/tree/ci/a) | 29d |'),
    );
    expect(md, contains('## In review (1)'));
    expect(md, contains('https://x/pull/1'));
    expect(md, contains('| 2 commits |'));
    expect(md, contains('Not listed: 1 kept branches'));
    expect(md, contains('1 upstream branches in 1 forks'));
  });
}
