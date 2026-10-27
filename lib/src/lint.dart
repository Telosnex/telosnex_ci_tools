import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'job_names.dart';

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

/// The findings of every workflow file in `<repo>/.github/workflows`, and
/// of the `web/index.html` of each Flutter app in the repository.
List<Finding> lintRepository(String repo) {
  final allowMatrix = _isSelf(repo);
  final dir = Directory(p.join(repo, '.github', 'workflows'));
  final files = dir.existsSync()
      ? (dir.listSync().whereType<File>().toList()
          ..sort((a, b) => a.path.compareTo(b.path)))
      : <File>[];
  return [
    for (final file in files)
      ...lintWorkflow(
        p.relative(file.path, from: repo),
        file.readAsStringSync(),
        allowMatrix: allowMatrix,
      ),
    for (final file in _webIndexFiles(repo))
      ...lintWebIndex(
        p.relative(file.path, from: repo),
        file.readAsStringSync(),
      ),
    for (final file in _driveTargets(repo, files))
      ...lintDriveTarget(
        p.relative(file.path, from: repo),
        file.readAsStringSync(),
      ),
  ];
}

/// Whether [repo] is telosnex_ci_tools: its reusable workflows may use a
/// matrix (a caller sees them in a box of their own anyway).
bool _isSelf(String repo) {
  final pubspec = File(p.join(repo, 'pubspec.yaml'));
  return pubspec.existsSync() &&
      RegExp(
        r'^name:\s*telosnex_ci_tools\s*$',
        multiLine: true,
      ).hasMatch(pubspec.readAsStringSync());
}

/// The `--target` files of the `flutter drive` commands of [workflows],
/// found at the repository root or in `example/`.
List<File> _driveTargets(String repo, List<File> workflows) {
  final targets = <String>{};
  for (final workflow in workflows) {
    // One command per line, with the backslash continuations joined: only
    // the -t of flutter drive counts, not the one of flutter build.
    final commands = workflow
        .readAsStringSync()
        .replaceAll(RegExp(r'\\\r?\n'), ' ')
        .split('\n')
        .where((line) => line.contains('flutter drive'));
    for (final command in commands) {
      for (final m in _driveTarget.allMatches(command)) {
        if (!m[1]!.contains(r'$')) targets.add(m[1]!);
      }
    }
  }
  final files = <String, File>{};
  for (final target in targets) {
    for (final root in [repo, p.join(repo, 'example')]) {
      final file = File(p.join(root, target));
      if (file.existsSync()) files[p.normalize(file.path)] = file;
    }
  }
  return files.values.toList()..sort((a, b) => a.path.compareTo(b.path));
}

/// The findings of a test file that `flutter drive` runs.
///
/// integration_test reports only testWidgets results to the driver: a
/// failing test() still ends with "All tests passed".
List<Finding> lintDriveTarget(String path, String text) {
  final lines = text.split('\n');
  return [
    for (var i = 0; i < lines.length; i++)
      if (_plainTest.hasMatch(lines[i]))
        Finding(
          path,
          i + 1,
          'drive-test-widgets',
          'Use testWidgets: flutter drive does not get the results of '
              'test(), and a failing test() passes.',
        ),
  ];
}

/// `web/index.html` of the repository, of `example/`, and of the packages
/// one level down (`super_native_extensions/example/web/index.html`).
List<File> _webIndexFiles(String repo) {
  final roots = <String>[repo, p.join(repo, 'example')];
  final top = Directory(repo);
  if (top.existsSync()) {
    for (final d in top.listSync().whereType<Directory>()) {
      final name = p.basename(d.path);
      if (name.startsWith('.') || name == 'build' || name == 'example') {
        continue;
      }
      roots
        ..add(d.path)
        ..add(p.join(d.path, 'example'));
    }
  }
  return [
    for (final root in roots)
      if (File(p.join(root, 'web', 'index.html')) case final f
          when f.existsSync())
        f,
  ]..sort((a, b) => a.path.compareTo(b.path));
}

/// The findings of one Flutter `web/index.html`.
///
/// The legacy loader (`flutter.js` with `loadEntrypoint`, or a
/// `main.dart.js` script) always runs `main.dart.js`. In a `--wasm` build the
/// app then stalls, or runs the JS build while the test claims Wasm.
List<Finding> lintWebIndex(String path, String text) {
  final flutterApp =
      text.contains('flutter.js') || text.contains('main.dart.js');
  if (!flutterApp || text.contains('flutter_bootstrap.js')) return const [];
  final lines = text.split('\n');
  final line = lines.indexWhere(
    (l) => l.contains('flutter.js') || l.contains('main.dart.js'),
  );
  return [
    Finding(
      path,
      line + 1,
      'flutter-bootstrap',
      'Load flutter_bootstrap.js: <script src="flutter_bootstrap.js" async>. '
          'The legacy loader runs main.dart.js in a --wasm build.',
    ),
  ];
}

/// The findings of one workflow file. [path] is relative to the repository.
List<Finding> lintWorkflow(
  String path,
  String text, {
  bool allowMatrix = false,
}) {
  final findings = <Finding>[];
  void add(int line, String rule, String message) =>
      findings.add(Finding(path, line, rule, message));

  final fileName = p.basename(path);
  final fileNameOk = RegExp(
    r'^[a-z0-9]+(_[a-z0-9]+)*\.yml$',
  ).hasMatch(fileName);
  if (!fileNameOk) {
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
    if (problem == null &&
        fileNameOk &&
        name.toLowerCase() != expected.toLowerCase()) {
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
  final workflowShell = _defaultShell(root);
  var callsShared = false;
  for (final MapEntry(:key, :value) in jobs.nodes.entries) {
    if (value is! YamlMap) continue;
    final jobDefaults = value.nodes['defaults'];
    if (workflowShell != null &&
        jobDefaults is YamlMap &&
        jobDefaults['run'] is YamlMap &&
        _defaultShell(value) == null) {
      add(
        _line(jobDefaults),
        'job-defaults-shell',
        'Set shell: $workflowShell in the defaults.run of job '
            '${(key as YamlNode).value}. Job defaults replace the workflow '
            'defaults: without it, steps run in sh or PowerShell.',
      );
    }
    final strategy = value.nodes['strategy'];
    final matrix = strategy is YamlMap ? strategy.nodes['matrix'] : null;
    if (!allowMatrix && matrix != null) {
      add(
        _line(matrix),
        'no-matrix',
        'Write each job of the matrix of job ${(key as YamlNode).value} '
            'out: GitHub puts a matrix in one box of the run graph. Share '
            'the steps with a YAML anchor (steps: &name, then steps: *name).',
      );
    }
    for (final (line, jobName) in _jobNames(value)) {
      final problem = jobNameProblem(jobName);
      if (problem != null) add(line, 'job-name', problem);
    }
    final jobShell = _defaultShell(value) ?? workflowShell;
    final steps = value.nodes['steps'];
    if (steps is YamlList) {
      for (final step in steps.nodes) {
        if (step is! YamlMap) continue;
        final run = step.nodes['run'];
        if (run is! YamlScalar || run.value is! String) continue;
        final script = run.value as String;
        if (!_pipeToTee.hasMatch(script) || script.contains('pipefail')) {
          continue;
        }
        final shell = step['shell'] ?? jobShell;
        if (shell == 'bash' ||
            (shell is String && shell.contains('pipefail'))) {
          continue;
        }
        add(
          _line(run),
          'tee-pipefail',
          'A pipe into tee hides the exit code of the command before it. '
              'Set shell: bash (bash -eo pipefail) on the step, job or '
              'workflow defaults.',
        );
      }
    }
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

/// The names of a job: its `name`, or for `${{ matrix.X }}` names, X of each
/// `strategy.matrix.include` entry (and of each value of a list `X:`).
/// Names with other expressions are not checked.
Iterable<(int, String)> _jobNames(YamlMap job) sync* {
  final node = job.nodes['name'];
  final name = node?.value;
  if (name is! String) return;
  final matrixName = RegExp(
    r'^\$\{\{\s*matrix\.([\w-]+)\s*\}\}$',
  ).firstMatch(name);
  if (matrixName == null) {
    if (!name.contains(r'${{')) yield (_line(node!), name);
    return;
  }
  final key = matrixName[1]!;
  final strategy = job['strategy'];
  final matrix = strategy is YamlMap ? strategy.nodes['matrix'] : null;
  if (matrix is! YamlMap) return;
  final include = matrix.nodes['include'];
  if (include is YamlList) {
    for (final entry in include.nodes) {
      if (entry is! YamlMap) continue;
      final value = entry.nodes[key];
      if (value is YamlScalar && value.value is String) {
        yield (_line(value), value.value as String);
      }
    }
  }
  final list = matrix.nodes[key];
  if (list is YamlList) {
    for (final value in list.nodes) {
      if (value is YamlScalar && value.value is String) {
        yield (_line(value), value.value as String);
      }
    }
  }
}

final _platformWord = RegExp(
  '\\b(${[...platforms, ...browsers, 'mac[Oo][Ss]', 'MacOS', 'iPhone', 'arm64', 'X64', 'amd64', 'x86_64', 'aarch64'].join('|')})\\b',
);

/// Null if a job name is in the Telosnex form (README, "Job names"):
/// `<Platform> <Arch> [detail]` (`Windows ARM64`, `iOS ARM64 simulator`) or
/// `Web <Platform> <Arch> <Browser> [detail]` (`Web Linux x64 Chrome
/// dart2wasm`). Names without a platform or browser (`Unit`, `Web files`)
/// only need sentence case.
String? jobNameProblem(String name) {
  if (parseJobName(name) != null) return null;
  if (_platformWord.hasMatch(name)) {
    return 'Name the job "<Platform> <Arch> [detail]" or '
        '"Web <Platform> <Arch> <Browser> [detail]", e.g. "Windows ARM64", '
        '"Web Linux x64 Chrome dart2wasm" (platforms: ${platforms.join(', ')}; '
        'archs: ${archs.join(', ')}; browsers: ${browsers.join(', ')}), '
        'not "$name".';
  }
  return nameProblem(name);
}

/// `defaults.run.shell` of a workflow or job map, or null.
Object? _defaultShell(YamlMap map) {
  final defaults = map['defaults'];
  if (defaults is! YamlMap) return null;
  final run = defaults['run'];
  if (run is! YamlMap) return null;
  return run['shell'];
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
  // Capitalized words only: product names with inner capitals (BoringSSL,
  // macOS, WebGPU) and acronyms are not Title Case.
  final capitalized = RegExp(r'^[A-Z][a-z0-9.\-]*$');
  final titleWords = words
      .skip(1)
      .where((w) => capitalized.hasMatch(w) && !acronym.hasMatch(w));
  if (words.length > 1 && titleWords.length == words.length - 1) {
    return 'Write the name "$name" in sentence case.';
  }
  return null;
}

final _uses = RegExp(r'''^\s*(?:-\s+)?uses:\s*['"]?([^\s'"]+)['"]?(.*)$''');
final _pinned = RegExp(r'^[\w.-]+/[\w.-]+(/[^@]+)?@[0-9a-f]{40}$');
final _versionComment = RegExp(r'^\s*#\s*\S+');
final _driveTarget = RegExp(r'(?:--target[ =]|\s-t\s+)(\S+\.dart)');
final _plainTest = RegExp(r'^\s*test\(');
final _pipeToTee = RegExp(r'\|\s*tee\b');
final _cacheSubaction = RegExp(r'^actions/cache/(restore|save)@');
final _flutterClone = RegExp(r'github\.com/flutter/flutter(\.git)?\b');

void _lintLines(String text, void Function(int, String, String) add) {
  final lines = text.split('\n');
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    if (line.trimLeft().startsWith('#')) continue;
    if (_mergeKey.hasMatch(line)) {
      add(
        i + 1,
        'no-merge-key',
        'GitHub Actions rejects the YAML merge key <<: the run fails at '
            'startup. Alias whole values instead (steps: *name).',
      );
    }
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
      final subaction = _cacheSubaction.firstMatch(ref);
      if (subaction != null) {
        add(
          i + 1,
          'allowed-actions',
          'Use actions/cache, not actions/cache/${subaction[1]}. The '
              'Telosnex allow list has only actions/cache: the run fails at '
              'startup.',
        );
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

final _mergeKey = RegExp(r'^\s*(- )?<<\s*:');

const _setupFlutter =
    'Install Flutter with $selfRepository/actions/setup-flutter.';

int _line(YamlNode node) => node.span.start.line + 1;
