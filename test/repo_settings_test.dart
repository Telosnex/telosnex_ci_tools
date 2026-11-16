import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:telosnex_ci_tools/src/lint.dart';
import 'package:telosnex_ci_tools/src/repo_settings.dart';
import 'package:test/test.dart';

void main() {
  test('no file, or an empty file, is the defaults', () {
    final dir = Directory.systemTemp.createTempSync('settings');
    addTearDown(() => dir.deleteSync(recursive: true));
    expect(RepoSettings.read(dir.path).releaseManual, isFalse);
    expect(RepoSettings.parse('').lintExceptions, isEmpty);
  });

  test('release: manual and lint exceptions', () {
    final settings = RepoSettings.parse('''
release: manual
lint_exceptions:
  - rule: job-name
    file: '*'
    reason: Not on the dashboard.
''');
    expect(settings.releaseManual, isTrue);
    final e = settings.lintExceptions.single;
    expect(
      (e.rule, e.file, e.reason, e.line),
      ('job-name', '*', 'Not on the dashboard.', 3),
    );
  });

  for (final (name, text, line) in [
    ('an unknown key', 'release: manual\nrelaese: manual\n', 2),
    ('another release value', 'release: auto\n', 1),
    ('a list that is not a list', 'lint_exceptions: job-name\n', 1),
    (
      'an entry with no reason',
      'lint_exceptions:\n  - {rule: a, file: b}\n',
      2,
    ),
    (
      'an entry with an extra key',
      'lint_exceptions:\n  - {rule: a, file: b, reason: c, d: e}\n',
      2,
    ),
    ('invalid YAML', 'release: [\n', 2),
  ]) {
    test('rejects $name', () {
      expect(
        () => RepoSettings.parse(text),
        throwsA(isA<SettingsException>().having((e) => e.line, 'line', line)),
      );
    });
  }

  group('applyExceptions', () {
    const a = Finding('.github/workflows/a.yml', 3, 'job-name', 'm');
    const b = Finding('.github/workflows/b.yml', 4, 'job-name', 'm');
    const c = Finding('.github/workflows/b.yml', 5, 'timeout', 'm');

    test('* matches every file, a path only its own', () {
      final settings = RepoSettings.parse('''
lint_exceptions:
  - {rule: job-name, file: '*', reason: r}
  - {rule: timeout, file: .github/workflows/b.yml, reason: r}
''');
      expect(applyExceptions([a, b, c], settings), isEmpty);
    });

    test('keeps other findings and reports stale exceptions', () {
      final settings = RepoSettings.parse('''
lint_exceptions:
  - {rule: job-name, file: .github/workflows/a.yml, reason: r}
  - {rule: timeout, file: .github/workflows/a.yml, reason: r}
''');
      expect(applyExceptions([a, b, c], settings).map((f) => '$f'), [
        '$b',
        '$c',
        '$settingsPath:3: stale-exception: Remove the exception of timeout '
            'for .github/workflows/a.yml: it matches no finding.',
      ]);
    });
  });

  test('lintRepository applies the settings and reports a bad file', () {
    final dir = Directory.systemTemp.createTempSync('settings');
    addTearDown(() => dir.deleteSync(recursive: true));
    Directory(
      p.join(dir.path, '.github', 'workflows'),
    ).createSync(recursive: true);
    File(
      p.join(dir.path, '.github', 'workflows', 'unit.yml'),
    ).writeAsStringSync('''
name: Unit
permissions: {}
on: push
jobs:
  unit:
    timeout-minutes: 5
    runs-on: ubuntu-latest
    steps:
      - run: true
''');
    final settings = File(p.join(dir.path, settingsPath));
    expect(lintRepository(dir.path).map((f) => f.rule), ['lint-step']);

    settings.writeAsStringSync('''
lint_exceptions:
  - {rule: lint-step, file: '*', reason: r}
''');
    expect(lintRepository(dir.path), isEmpty);

    settings.writeAsStringSync('nope: 1\n');
    expect(lintRepository(dir.path).map((f) => f.rule), ['settings']);
  });
}
