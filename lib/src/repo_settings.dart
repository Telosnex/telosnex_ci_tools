import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'lint.dart' show Finding;

/// The path of the settings file, relative to the repository.
final settingsPath = p.join('.github', 'telosnex_ci_tools.yaml');

/// The settings of telosnex_ci_tools for one repository, from
/// `.github/telosnex_ci_tools.yaml`:
///
/// ```yaml
/// # The release command does not change this repository.
/// release: manual
///
/// # Lint rules that do not apply here. A stale entry is a finding.
/// lint_exceptions:
///   - rule: job-name
///     file: '*' # or one path, such as .github/workflows/unit.yml
///     reason: Why the rule does not apply.
/// ```
final class RepoSettings {
  const RepoSettings({
    this.releaseManual = false,
    this.lintExceptions = const [],
  });

  /// `release: manual`: the release command skips the repository.
  final bool releaseManual;
  final List<LintException> lintExceptions;

  /// The settings of [repo]. Defaults if the file does not exist.
  /// Throws a [SettingsException] if the file is not valid.
  static RepoSettings read(String repo) {
    final file = File(p.join(repo, settingsPath));
    return file.existsSync()
        ? parse(file.readAsStringSync())
        : const RepoSettings();
  }

  static RepoSettings parse(String text) {
    final YamlNode root;
    try {
      root = loadYamlNode(text, sourceUrl: Uri.file(settingsPath));
    } on YamlException catch (e) {
      throw SettingsException(e.message, (e.span?.start.line ?? 0) + 1);
    }
    if (root is YamlScalar && root.value == null) return const RepoSettings();
    if (root is! YamlMap) {
      throw SettingsException('The settings are not a YAML map.', 1);
    }
    for (final key in root.nodes.keys.cast<YamlNode>()) {
      if (!const {'release', 'lint_exceptions'}.contains(key.value)) {
        throw SettingsException(
          'Unknown key ${key.value}. Known: release, lint_exceptions.',
          key.span.start.line + 1,
        );
      }
    }
    final release = root.nodes['release'];
    if (release != null && release.value != 'manual') {
      throw SettingsException(
        'release can only be manual.',
        release.span.start.line + 1,
      );
    }
    final list = root.nodes['lint_exceptions'];
    if (list != null && list is! YamlList) {
      throw SettingsException(
        'lint_exceptions is not a list.',
        list.span.start.line + 1,
      );
    }
    return RepoSettings(
      releaseManual: release != null,
      lintExceptions: [
        for (final entry in (list as YamlList?)?.nodes ?? <YamlNode>[])
          LintException._parse(entry),
      ],
    );
  }
}

/// One entry of `lint_exceptions`.
final class LintException {
  const LintException(this.rule, this.file, this.reason, this.line);

  final String rule;

  /// A path relative to the repository, or `*` for every file.
  final String file;
  final String reason;

  /// 1-based line in the settings file.
  final int line;

  bool matches(Finding finding) =>
      finding.rule == rule && (file == '*' || p.equals(file, finding.path));

  static LintException _parse(YamlNode node) {
    final line = node.span.start.line + 1;
    if (node is! YamlMap) {
      throw SettingsException('A lint exception is not a map.', line);
    }
    final keys = node.keys.toSet();
    if (!keys.containsAll(const {'rule', 'file', 'reason'}) ||
        keys.length != 3) {
      throw SettingsException(
        'A lint exception has exactly rule, file and reason.',
        line,
      );
    }
    String text(String key) {
      final value = node[key];
      if (value is! String || value.trim().isEmpty) {
        throw SettingsException('$key is empty.', line);
      }
      return value;
    }

    return LintException(text('rule'), text('file'), text('reason'), line);
  }
}

/// [findings] without the ones that [settings] excepts, plus a finding for
/// each exception that matches nothing.
List<Finding> applyExceptions(List<Finding> findings, RepoSettings settings) {
  final used = <LintException>{};
  final kept = <Finding>[];
  for (final finding in findings) {
    final match = settings.lintExceptions.where((e) => e.matches(finding));
    if (match.isEmpty) {
      kept.add(finding);
    } else {
      used.addAll(match);
    }
  }
  return [
    ...kept,
    for (final e in settings.lintExceptions)
      if (!used.contains(e))
        Finding(
          settingsPath,
          e.line,
          'stale-exception',
          'Remove the exception of ${e.rule} for ${e.file}: it matches no '
              'finding.',
        ),
  ];
}

/// An invalid settings file.
final class SettingsException implements Exception {
  const SettingsException(this.message, this.line);

  final String message;

  /// 1-based.
  final int line;

  @override
  String toString() => '$settingsPath:$line: $message';
}
