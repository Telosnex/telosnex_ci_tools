import 'package:telosnex_ci_tools/src/repos.dart';
import 'package:test/test.dart';

void main() {
  test('parseGitHubUrl: https, ssh, .git, case', () {
    expect(parseGitHubUrl('https://github.com/Telosnex/fonnx.git'), (
      'Telosnex',
      'fonnx',
    ));
    expect(parseGitHubUrl('https://github.com/telosnex/archive'), (
      'telosnex',
      'archive',
    ));
    expect(parseGitHubUrl('git@github.com:Telosnex/dart-sprintf.git'), (
      'Telosnex',
      'dart-sprintf',
    ));
    expect(parseGitHubUrl('https://github.com/Telosnex/highlight.dart.git'), (
      'Telosnex',
      'highlight.dart',
    ));
    expect(parseGitHubUrl('https://gitlab.com/a/b.git'), isNull);
  });

  test('referencesIn: pubspec sections, short and long git forms', () {
    const pubspec = '''
name: app
dependencies:
  a:
    git:
      url: https://github.com/Telosnex/a.git
      ref: x
  b:
    git: https://github.com/Telosnex/b
  c: ^1.0.0
dev_dependencies:
  d:
    git:
      url: https://github.com/other/d.git
dependency_overrides:
  e:
    git:
      url: https://github.com/Telosnex/e-repo.git
      path: packages/e
''';
    final refs = referencesIn('pubspec.yaml', pubspec);
    expect(
      [for (final r in refs) '${r.package}:${r.key}'],
      ['a:telosnex/a', 'b:telosnex/b', 'd:other/d', 'e:telosnex/e-repo'],
    );
    expect(refs.any((r) => r.fromLock), isFalse);
  });

  test('referencesIn: pubspec.lock git packages only', () {
    const lock = '''
packages:
  a:
    dependency: transitive
    description:
      path: "."
      ref: abc
      resolved-ref: abc
      url: "https://github.com/Telosnex/a.git"
    source: git
    version: "1.0.0"
  b:
    dependency: direct main
    description:
      name: b
      url: "https://pub.dev"
    source: hosted
    version: "1.0.0"
''';
    final refs = referencesIn('dev/x/pubspec.lock', lock);
    expect(refs.single.key, 'telosnex/a');
    expect(refs.single.fromLock, isTrue);
  });

  test('referencesIn: not YAML is no references', () {
    expect(referencesIn('pubspec.yaml', ': : :\n  - ['), isEmpty);
  });

  test('actionRepos: actions and reusable workflows of the org', () {
    const workflow = '''
jobs:
  a:
    uses: Telosnex/telosnex_ci_tools/.github/workflows/k.yml@abc
  b:
    steps:
      - uses: Telosnex/flutter-action@e08e50d
      - uses: "telosnex/cache@v4"
      - uses: actions/checkout@v4
      # - uses: Telosnex/commented@x
''';
    expect(actionRepos(workflow, 'Telosnex'), {
      'telosnex_ci_tools',
      'flutter-action',
      'cache',
    });
  });

  test('category: CI tools, then use', () {
    OrgRepo repo({bool ci = false, bool used = false}) => OrgRepo(
      name: 'r',
      isFork: true,
      isArchived: false,
      usesCiTools: ci,
      references: [
        if (used)
          const RepoReference(
            owner: 'Telosnex',
            repo: 'r',
            file: 'pubspec.lock',
            package: 'r',
          ),
      ],
    );
    expect(repo(ci: true).category, ForkCategory.live);
    expect(repo(ci: true, used: true).category, ForkCategory.live);
    expect(repo(used: true).category, ForkCategory.missingCi);
    expect(repo(used: true).usedTransitively, isTrue);
    expect(repo().category, ForkCategory.unused);
  });

  test('hostedPackagesIn and pubspecName', () {
    const lock = '''
packages:
  kiln:
    dependency: transitive
    description:
      name: kiln
      url: "https://pub.dev"
    source: hosted
    version: "0.1.1"
  a:
    description:
      url: "https://github.com/Telosnex/a.git"
    source: git
''';
    expect(hostedPackagesIn(lock), {'kiln'});
    expect(pubspecName('name: kiln\nversion: 1.0.0\n'), 'kiln');
    expect(pubspecName(': ['), isNull);
  });

  test('parseSkips: lowercase names, reasons required', () {
    expect(parseSkips('skip:\n  - repo: Foo\n    reason: a tool\n'), {
      'foo': 'a tool',
    });
    expect(parseSkips('other: 1\n'), isEmpty);
    expect(() => parseSkips('skip:\n  - repo: foo\n'), throwsFormatException);
  });

  test('category: a skip wins', () {
    const repo = OrgRepo(
      name: 'r',
      isFork: false,
      isArchived: false,
      usesCiTools: true,
      skipReason: 'tool',
    );
    expect(repo.category, ForkCategory.skipped);
  });
}
