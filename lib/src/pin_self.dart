import 'dart:io';

import 'package:path/path.dart' as p;

import 'lint.dart';

/// The files that the self references point into. A change to one of them
/// needs a new pin.
const pinnedPaths = ['actions', 'flutter_version.txt'];

/// A reference to an action of this repository and its comment.
final selfReference = RegExp(
  '(${RegExp.escape(selfRepository)}/actions/[\\w-]+)@(\\S+)( # self)?',
);

final class PinException implements Exception {
  const PinException(this.message);

  final String message;
}

/// Sets every self reference in the workflow files to HEAD. The actions must
/// be committed.
Future<({String sha, List<String> changed})> pinSelf(String root) async {
  final dirty = await _git(root, [
    'status',
    '--porcelain',
    '--',
    ...pinnedPaths,
  ]);
  if (dirty.isNotEmpty) {
    throw PinException(
      'Commit the changes to ${pinnedPaths.join(' and ')} first:\n$dirty',
    );
  }
  final sha = await _git(root, ['rev-parse', 'HEAD']);
  final changed = <String>[];
  for (final file in _workflowFiles(root)) {
    final text = file.readAsStringSync();
    final pinned = text.replaceAllMapped(
      selfReference,
      (m) => '${m[1]}@$sha # self',
    );
    if (pinned != text) {
      file.writeAsStringSync(pinned);
      changed.add(p.relative(file.path, from: root));
    }
  }
  return (sha: sha, changed: changed);
}

/// Returns the pinned commit. Throws if the references name different
/// commits, or if [pinnedPaths] changed after that commit.
Future<String> checkSelfPins(String root) async {
  final shas = <String>{};
  for (final file in _workflowFiles(root)) {
    for (final m in selfReference.allMatches(file.readAsStringSync())) {
      shas.add(m[2]!);
    }
  }
  if (shas.isEmpty) throw const PinException('No self references found.');
  if (shas.length > 1) {
    throw PinException(
      'The self references name ${shas.length} commits: ${shas.join(', ')}. '
      'Run `dart run telosnex_ci_tools:pin_self`.',
    );
  }
  final sha = shas.single;
  if (!RegExp(r'^[0-9a-f]{40}$').hasMatch(sha)) {
    throw PinException(
      'The self references name "$sha", not a commit SHA. '
      'Run `dart run telosnex_ci_tools:pin_self`.',
    );
  }
  final diff = await _git(root, [
    'diff',
    '--stat',
    sha,
    'HEAD',
    '--',
    ...pinnedPaths,
  ]);
  if (diff.isNotEmpty) {
    throw PinException(
      'The actions changed after $sha:\n$diff\n'
      'Run `dart run telosnex_ci_tools:pin_self` and commit.',
    );
  }
  return sha;
}

Iterable<File> _workflowFiles(String root) {
  final dir = Directory(p.join(root, '.github', 'workflows'));
  if (!dir.existsSync()) return const [];
  return dir.listSync().whereType<File>().where((f) => f.path.endsWith('.yml'));
}

Future<String> _git(String root, List<String> args) async {
  final result = await Process.run('git', args, workingDirectory: root);
  if (result.exitCode != 0) {
    throw PinException('git ${args.join(' ')} failed:\n${result.stderr}');
  }
  return '${result.stdout}'.trim();
}
