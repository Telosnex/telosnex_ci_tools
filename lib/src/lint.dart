import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// The prefix of every action and reusable workflow of this repository.
const selfRepository = 'Telosnex/telosnex_ci_tools';

/// One rule violation.
final class Finding {
  const Finding(this.path, this.line, this.rule, this.message);

  final String path;

  /// 1-based.
  final int line;
  final String rule;
  final String message;

  @override
  String toString() => '$path:$line: $rule: $message';

  /// A GitHub Actions workflow command. GitHub shows it on the file.
  String toAnnotation() =>
      '::error file=$path,line=$line,title=$rule::$message';
}

/// The findings of every workflow file in `<repo>/.github/workflows`.
List<Finding> lintRepository(String repo) {
  final dir = Directory(p.join(repo, '.github', 'workflows'));
  if (!dir.existsSync()) return const [];
  final files = dir.listSync().whereType<File>().toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  return [
    for (final file in files)
      ...lintWorkflow(
        p.relative(file.path, from: repo),
        file.readAsStringSync(),
      ),
  ];
}

/// The findings of one workflow file. [path] is relative to the repository.
List<Finding> lintWorkflow(String path, String text) {
  final findings = <Finding>[];
  void add(int line, String rule, String message) =>
      findings.add(Finding(path, line, rule, message));

  final fileName = p.basename(path);
  if (!RegExp(r'^[a-z0-9]+(_[a-z0-9]+)*\.yml$').hasMatch(fileName)) {
    add(1, 'file-name', 'Name workflow files in snake_case with .yml.');
  }

  _lintLines(text, add);

  final YamlNode root;
  try {
    root = loadYamlNode(text, sourceUrl: Uri.file(path));
  } on YamlException catch (e) {
    add((e.span?.start.line ?? 0) + 1, 'yaml', e.message);
    return findings;
  }
  if (root is! YamlMap) {
    add(1, 'yaml', 'The workflow is not a YAML map.');
    return findings;
  }

  final nameNode = root.nodes['name'];
  final name = nameNode?.value;
  if (name is! String) {
    add(1, 'name', 'Give the workflow a name.');
  } else {
    final line = _line(nameNode!);
    final problem = nameProblem(name);
    if (problem != null) add(line, 'name', problem);
    final expected = nameForFile(fileName);
    if (problem == null && name.toLowerCase() != expected.toLowerCase()) {
      add(
        line,
        'name-matches-file',
        'The name "$name" and the file name $fileName differ. '
            'Name the workflow "$expected", or rename the file.',
      );
    }
  }

  if (!root.containsKey('permissions')) {
    add(1, 'permissions', 'Set the top-level permissions.');
  }

  final jobs = root.nodes['jobs'];
  if (jobs is! YamlMap) return findings;
  var callsShared = false;
  for (final MapEntry(:key, :value) in jobs.nodes.entries) {
    if (value is! YamlMap) continue;
    final uses = value['uses'];
    if (uses is String) {
      if (uses.startsWith('$selfRepository/')) {
        callsShared = true;
        if (value.containsKey('concurrency')) {
          add(
            _line(value),
            'shared-concurrency',
            'Remove the concurrency of job ${(key as YamlNode).value}. '
                'The shared workflow sets it.',
          );
        }
      }
    } else if (!value.containsKey('timeout-minutes')) {
      add(
        _line(key as YamlNode),
        'timeout',
        'Set timeout-minutes on job ${key.value}.',
      );
    }
  }
  if (callsShared && root.containsKey('concurrency')) {
    add(
      _line(root.nodes['concurrency']!),
      'shared-concurrency',
      'Remove the top-level concurrency. The shared workflow sets it. '
          'The same group in the caller and the shared workflow deadlocks.',
    );
  }
  return findings;
}

/// The workflow name for a file name: `native_release.yml` is
/// "Native release".
String nameForFile(String fileName) {
  final words = p.basenameWithoutExtension(fileName).split('_');
  final first = words.first;
  return [
    if (first.isNotEmpty) first[0].toUpperCase() + first.substring(1),
    ...words.skip(1),
  ].join(' ');
}

/// Null if [name] is in sentence case: a capital first letter, no Title Case,
/// no period at the end. Acronyms such as CUDA are allowed.
String? nameProblem(String name) {
  final startsUpper = RegExp(r'^[A-Z0-9]');
  if (!startsUpper.hasMatch(name)) {
    return 'Start the name "$name" with a capital letter.';
  }
  if (name.endsWith('.')) return 'Remove the period at the end of "$name".';
  final words = name.split(RegExp(r'\s+'));
  final acronym = RegExp(r'^[A-Z0-9]+$');
  final titleWords = words
      .skip(1)
      .where((w) => startsUpper.hasMatch(w) && !acronym.hasMatch(w));
  if (words.length > 1 && titleWords.length == words.length - 1) {
    return 'Write the name "$name" in sentence case.';
  }
  return null;
}

final _uses = RegExp(r'''^\s*(?:-\s+)?uses:\s*['"]?([^\s'"]+)['"]?(.*)$''');
final _pinned = RegExp(r'^[\w.-]+/[\w.-]+(/[^@]+)?@[0-9a-f]{40}$');
final _versionComment = RegExp(r'^\s*#\s*\S+');
final _flutterClone = RegExp(r'github\.com/flutter/flutter(\.git)?\b');

void _lintLines(String text, void Function(int, String, String) add) {
  final lines = text.split('\n');
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    if (line.trimLeft().startsWith('#')) continue;
    final uses = _uses.firstMatch(line);
    if (uses != null) {
      final ref = uses[1]!;
      final rest = uses[2]!;
      if (ref.startsWith('./') || ref.startsWith('docker://')) {
        // Local and Docker references have no tag.
      } else if (!_pinned.hasMatch(ref)) {
        add(i + 1, 'pinned-uses', 'Pin $ref to a full commit SHA.');
      } else if (!_versionComment.hasMatch(rest)) {
        add(i + 1, 'pinned-uses', 'Add the version comment, "# v1.2.3".');
      }
      if (ref.startsWith('subosito/flutter-action')) {
        add(i + 1, 'setup-flutter', _setupFlutter);
      }
    }
    if (_flutterClone.hasMatch(line)) {
      add(i + 1, 'setup-flutter', _setupFlutter);
    }
  }
}

const _setupFlutter =
    'Install Flutter with $selfRepository/actions/setup-flutter.';

int _line(YamlNode node) => node.span.start.line + 1;
