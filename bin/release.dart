/// dart run telosnex_ci_tools:release vX.Y.Z [--dry-run] [--only a,b]
///
/// Releases this repository and moves every package to it, in one step:
///
/// 1. If the tag does not exist yet: checks that this checkout is clean and
///    at origin/main, that the self pins are current (pin_self --check) and
///    that its workflows lint clean; then tags HEAD and pushes the tag.
///    If the tag exists, it is used as is: run the command with an older
///    tag to undo a release.
/// 2. For each repository of the organization whose workflows use this
///    repository: pins every reference to the tag's commit (the org requires
///    full commit SHAs, so a moving tag cannot be used), lints, commits and
///    pushes to the default branch. If the push is refused (a protected
///    branch), it pushes a branch and opens a pull request instead.
///
/// A repository is left alone if the new pins add lint findings.
/// --dry-run makes no tag, commit or push, and prints what would change.
library;

import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;
import 'package:telosnex_ci_tools/src/lint.dart';
import 'package:telosnex_ci_tools/src/pin_self.dart';
import 'package:telosnex_ci_tools/src/release.dart';

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addFlag('dry-run', negatable: false)
    ..addOption('only', help: 'Comma-separated repository names.')
    ..addOption('org', defaultsTo: 'Telosnex')
    ..addOption('jobs', defaultsTo: '6', help: 'Repositories at a time.')
    ..addFlag('help', abbr: 'h', negatable: false);
  final args = parser.parse(arguments);
  if (args.flag('help') || args.rest.length != 1) {
    stdout
      ..writeln(
        'dart run telosnex_ci_tools:release vX.Y.Z [--dry-run] [--only a,b]',
      )
      ..writeln(parser.usage);
    exitCode = args.flag('help') ? 0 : 64;
    return;
  }
  final tag = args.rest.single;
  if (!releaseTag.hasMatch(tag)) {
    _fail('$tag is not a release tag (vX.Y.Z).');
  }
  final dryRun = args.flag('dry-run');
  final org = args.option('org')!;
  final only = args.option('only')?.split(',').map((s) => s.trim()).toSet();
  final root = Directory.current.path;

  final sha = await _tag(root, tag, dryRun: dryRun);

  final repos = await _repositories(org, only);
  stdout.writeln(
    '${dryRun ? 'Dry run: ' : ''}pinning $selfRepository to $tag '
    '(${sha.substring(0, 12)}) in ${repos.length} repositories...',
  );
  final results = <String, String>{};
  final queue = [...repos];
  Future<void> worker() async {
    while (queue.isNotEmpty) {
      final (name, branch) = queue.removeAt(0);
      String result;
      try {
        result = await _update(org, name, branch, sha, tag, dryRun: dryRun);
      } on Object catch (e) {
        result = 'FAILED: $e';
      }
      results[name] = result;
      if (result.isNotEmpty) stdout.writeln('$name: $result');
    }
  }

  await Future.wait([
    for (var i = 0; i < int.parse(args.option('jobs')!); i++) worker(),
  ]);

  final failed = results.values.where(
    (r) => r.startsWith('FAILED') || r.startsWith('NOT UPDATED'),
  );
  final changed = results.values.where(
    (r) =>
        r.startsWith('pushed') ||
        r.startsWith('pull request') ||
        r.startsWith('would update'),
  );
  stdout.writeln(
    '\n${changed.length} ${dryRun ? 'to update' : 'updated'}, '
    '${results.values.where((r) => r.startsWith('already')).length} already '
    'at $tag, ${failed.length} need attention'
    '${dryRun ? ' (dry run: nothing pushed)' : ''}.',
  );
  if (failed.isNotEmpty) exitCode = 1;
}

/// The commit of [tag]: the existing tag, or a new one at HEAD.
Future<String> _tag(String root, String tag, {required bool dryRun}) async {
  if (!File(p.join(root, 'pubspec.yaml')).readAsStringSync().contains(
    RegExp(r'^name:\s*telosnex_ci_tools\s*$', multiLine: true),
  )) {
    _fail('Run this in a checkout of $selfRepository.');
  }
  await _git(root, ['fetch', '-q', '--tags', '--force', 'origin']);
  final existing = await _git(root, [
    'ls-remote',
    '--tags',
    'origin',
    'refs/tags/$tag^{}',
  ]);
  if (existing.isNotEmpty) {
    final sha = existing.split(RegExp(r'\s')).first;
    stdout.writeln('$tag exists (${sha.substring(0, 12)}): pinning to it.');
    return sha;
  }

  if ((await _git(root, ['status', '--porcelain'])).isNotEmpty) {
    _fail('The checkout has uncommitted changes.');
  }
  final head = await _git(root, ['rev-parse', 'HEAD']);
  final main = await _git(root, ['rev-parse', 'origin/main']);
  if (head != main) _fail('HEAD is not origin/main: pull or push first.');
  try {
    await checkSelfPins(root);
  } on PinException catch (e) {
    _fail(
      '${e.message}\nRun `dart run telosnex_ci_tools:pin_self`, commit '
      'and push, then release again.',
    );
  }
  final findings = lintRepository(root);
  if (findings.isNotEmpty) {
    _fail('This repository has lint findings:\n${findings.join('\n')}');
  }
  if (dryRun) {
    stdout.writeln('Would tag HEAD (${head.substring(0, 12)}) as $tag.');
  } else {
    await _git(root, ['tag', '-a', tag, head, '-m', tag]);
    await _git(root, ['push', '-q', 'origin', 'refs/tags/$tag']);
    stdout.writeln('Tagged ${head.substring(0, 12)} as $tag and pushed it.');
  }
  return head;
}

/// Every non-archived repository of [org] but this one, with its default
/// branch.
Future<List<(String, String)>> _repositories(
  String org,
  Set<String>? only,
) async {
  final out = await _run('gh', [
    'repo',
    'list',
    org,
    '--limit',
    '1000',
    '--no-archived',
    '--json',
    'name,defaultBranchRef',
    '--jq',
    r'.[] | "\(.name) \(.defaultBranchRef.name)"',
  ]);
  final self = selfRepository.split('/').last;
  return [
    for (final line in out.split('\n'))
      if (line.split(' ') case [final name, final branch]
          when name != self &&
              branch.isNotEmpty &&
              (only == null || only.contains(name)))
        (name, branch),
  ]..sort((a, b) => a.$1.compareTo(b.$1));
}

/// Pins one repository. Returns what happened, or '' when it does not use
/// this repository.
Future<String> _update(
  String org,
  String name,
  String branch,
  String sha,
  String tag, {
  required bool dryRun,
}) async {
  final dir = Directory.systemTemp.createTempSync('release_$name');
  try {
    final repo = p.join(dir.path, 'r');
    await _run('git', [
      'clone',
      '-q',
      '--depth',
      '1',
      '--filter=blob:none',
      '--no-checkout',
      '--branch',
      branch,
      'https://github.com/$org/$name.git',
      repo,
    ]);
    // What the lint reads: workflows, actions, web/index.html files and
    // flutter drive targets.
    await _git(repo, [
      'sparse-checkout',
      'set',
      '--no-cone',
      '/.github/',
      '/actions/',
      'web/index.html',
      'integration_test/',
      'test_driver/',
    ]);
    await _git(repo, ['checkout', '-q', branch]);

    final files = [
      for (final d in ['.github', 'actions'])
        if (Directory(p.join(repo, d)).existsSync())
          ...Directory(p.join(repo, d))
              .listSync(recursive: true)
              .whereType<File>()
              .where((f) => RegExp(r'\.ya?ml$').hasMatch(f.path)),
    ];
    final using = files.where((f) => usesTools(f.readAsStringSync())).toList();
    if (using.isEmpty) return '';

    final before = lintRepository(repo).map((f) => '$f').toSet();
    for (final file in using) {
      final text = file.readAsStringSync();
      final pinned = repin(text, sha, tag);
      if (pinned != text) file.writeAsStringSync(pinned);
    }
    if ((await _git(repo, ['status', '--porcelain'])).isEmpty) {
      return 'already at $tag';
    }
    final added = lintRepository(
      repo,
    ).map((f) => '$f').where((f) => !before.contains(f)).toList();
    if (added.isNotEmpty) {
      return 'NOT UPDATED, the new pins add lint findings:\n  '
          '${added.join('\n  ')}';
    }
    final stat = await _git(repo, ['diff', '--shortstat']);
    if (dryRun) return 'would update ($stat)';

    await _git(repo, ['commit', '-qam', 'ci: $selfRepository $tag']);
    final push = await Process.run('git', [
      'push',
      '-q',
      'origin',
      'HEAD:$branch',
    ], workingDirectory: repo);
    if (push.exitCode == 0) return 'pushed ($stat)';

    final head = 'ci/telosnex-ci-tools-$tag';
    await _git(repo, ['push', '-q', '-f', 'origin', 'HEAD:refs/heads/$head']);
    final url = await _run('gh', [
      'pr',
      'create',
      '-R',
      '$org/$name',
      '--base',
      branch,
      '--head',
      head,
      '--title',
      'ci: $selfRepository $tag',
      '--body',
      'Pins $selfRepository to $tag. Opened by '
          '`dart run telosnex_ci_tools:release $tag`: a direct push to '
          '$branch was refused.',
    ]);
    return 'pull request $url';
  } finally {
    dir.deleteSync(recursive: true);
  }
}

Future<String> _git(String dir, List<String> args) =>
    _run('git', ['-C', dir, ...args]);

Future<String> _run(String executable, List<String> args) async {
  final result = await Process.run(executable, args);
  if (result.exitCode != 0) {
    throw ProcessException(
      executable,
      args,
      '${result.stderr}'.trim(),
      result.exitCode,
    );
  }
  return '${result.stdout}'.trim();
}

Never _fail(String message) {
  stderr.writeln(message);
  exit(1);
}
