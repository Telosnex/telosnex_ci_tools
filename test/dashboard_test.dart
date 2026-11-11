import 'dart:convert';
import 'dart:io';
import 'package:telosnex_ci_tools/src/dashboard.dart';
import 'package:telosnex_ci_tools/src/dashboard_fetch.dart';
import 'package:telosnex_ci_tools/src/job_names.dart';
import 'package:test/test.dart';

extension on String {
  T let<T>(T Function(String) f) => f(this);
}

/// A table row's cells.
List<String> _cells(String line) => line.split(' | ');

DashboardJob _job(String name, [String? conclusion = 'success']) =>
    DashboardJob(name: name, conclusion: conclusion, url: 'https://x/$name');

DashboardRun _run(
  String file,
  List<DashboardJob> jobs,
  DateTime at, {
  String? conclusion,
}) => DashboardRun(
  workflowFile: file,
  workflowName: file == 'unit.yml' ? 'Unit' : 'Integration',
  branch: 'main',
  sha: 'abcdef0123456789',
  event: 'push',
  conclusion:
      conclusion ??
      (jobs.any((j) => j.conclusion == 'failure') ? 'failure' : 'success'),
  url: 'https://x/run/$file',
  finishedAt: at,
  jobs: jobs,
);

void main() {
  test('runMark: ❌ when a job failed, 🚫 when jobs were only cancelled', () {
    final now = DateTime.utc(2026);
    DashboardRun run(List<String> jobs) => _run(
      'integration.yml',
      [for (final (i, c) in jobs.indexed) _job('J$i', c)],
      now,
      conclusion: 'failure',
    );
    expect(runMark(run(['success', 'cancelled'])), '🚫');
    expect(runMark(run(['failure', 'cancelled'])), '❌');
    expect(runMark(run(['success'])), '❌');
    expect(runMark(run([])), '❌');
  });

  group('parseJobName', () {
    test('native', () {
      final cell = parseJobName('iOS ARM64 simulator')!;
      expect(cell.platform, 'iOS');
      expect(cell.arch, 'ARM64');
      expect(cell.browser, isNull);
      expect(cell.detail, 'simulator');
      expect(cell.column, 'iOS ARM64');
    });

    test('web', () {
      final cell = parseJobName('Web Linux x64 Chrome dart2wasm')!;
      expect(cell.platform, 'Linux');
      expect(cell.browser, 'Chrome');
      expect(cell.detail, 'dart2wasm');
      expect(cell.column, 'Web Chrome');
    });

    test('others', () {
      expect(parseJobName('Unit'), isNull);
      expect(parseJobName('desktop / linux-x64'), isNull);
    });

    test('chroot is the usual way to run Android ARM64', () {
      final cell = parseJobName('Android ARM64 chroot')!;
      expect(cell.column, 'Android ARM64');
      expect(cell.isNormal, isTrue);
    });

    test('container is the usual way to run Android ARM64', () {
      final cell = parseJobName('Android ARM64 container')!;
      expect(cell.column, 'Android ARM64');
      expect(cell.isNormal, isTrue);
    });

    test('columns: alphabetical ignoring case, web last', () {
      final names = [
        'Web Linux x64 Safari',
        'Windows x64',
        'macOS ARM64',
        'Web Linux x64 Chrome',
        'iOS ARM64 simulator',
        'Linux x64',
        'Android x64 emulator',
        'Linux ARM64',
      ];
      final columns = [for (final n in names) parseJobName(n)!.column]
        ..sort(JobCell.compareColumns);
      expect(columns, [
        'Android x64',
        'iOS ARM64',
        'Linux ARM64',
        'Linux x64',
        'macOS ARM64',
        'Windows x64',
        'Web Chrome',
        'Web Safari',
      ]);
    });
  });

  group('renderDashboard', () {
    final now = DateTime.utc(2026, 10, 27, 12);
    final package = PackageStatus(
      const DashboardPackage(repo: 'Telosnex/pkg', checks: [], releases: []),
      'main',
      {
        'unit.yml': _run('unit.yml', [
          _job('Unit'),
        ], now.subtract(const Duration(hours: 2))),
        'integration.yml': _run('integration.yml', [
          _job('Linux x64'),
          _job('Web Linux x64 Chrome dart2wasm'),
          _job('Web Linux x64 Chrome dart2js', 'failure'),
          _job('desktop / windows'),
          _job('Linux x64 fake camera'),
          _job('Android x64 emulator'),
        ], now.subtract(const Duration(minutes: 5))),
      },
    );
    final empty = PackageStatus(
      const DashboardPackage(repo: 'Telosnex/other', checks: [], releases: []),
      'main',
      const {},
    );
    final markdown = renderDashboard([package, empty], now);
    List<String> row(String name) {
      final table = markdown.split('| Package |').last;
      return table
          .split('\n')
          .firstWhere(
            (line) =>
                line.startsWith('| $name') || line.startsWith('| [$name]'),
          )
          .let(_cells);
    }

    test('Unit first, a column per cell, then one blank-headed column per '
        'other job', () {
      // pkg has one other job: one blank header, whatever its name.
      expect(
        markdown,
        contains(
          '| Package | Unit | Android x64 | Linux x64 | Web Chrome |   |\n',
        ),
      );
      final cells = row('pkg');
      expect(cells[1], '[✅](https://x/Unit "Unit")');
      // emulator is the usual way to run Android: in its column.
      expect(cells[2], contains('"Android x64 emulator"'));
      // The plain Linux job, then the extra target fake camera.
      expect(
        cells[3],
        '[✅](https://x/Linux x64 "Linux x64") '
        '[✅](https://x/Linux x64 fake camera "Linux x64 fake camera")',
      );
      // Both compilers in one column, in name order.
      expect(cells[4], startsWith('[❌]'));
      expect(cells[4], contains('dart2js'));
      expect(cells[4].indexOf('dart2js'), lessThan(cells[4].indexOf('wasm')));
      // Names with no platform: one each.
      expect(cells[5], startsWith('[✅ desktop / windows]'));
    });

    test('an extra target goes in a column another package has, and in a '
        'column of its own when none has it', () {
      final md = renderDashboard([
        package,
        PackageStatus(
          const DashboardPackage(
            repo: 'Telosnex/cam',
            checks: [],
            releases: [],
          ),
          'main',
          {
            'integration.yml': _run('integration.yml', [
              _job('Linux x64 no camera'),
              _job('Linux x64 fake camera'),
              _job('macOS ARM64 SwiftPM'),
            ], now),
          },
        ),
      ], now);
      final cells = md
          .split('| Package |')
          .last
          .split('\n')
          .firstWhere((l) => l.startsWith('| [cam]'))
          .let(_cells);
      // Linux x64 is a column (pkg's plain job): both, by name.
      expect(cells[3], contains('"Linux x64 fake camera"'));
      expect(
        cells[3].indexOf('fake camera'),
        lessThan(cells[3].indexOf('no camera')),
      );
      // No package has macOS ARM64: a labelled column of its own.
      expect(cells[5], startsWith('[✅ macOS ARM64 SwiftPM]'));
    });

    test('a package with fewer other jobs leaves the rest empty', () {
      final cells = row('other');
      expect(cells[5], ' |');
    });

    test('no job is —', () {
      expect(row('other').sublist(1, 5), everyElement(startsWith('—')));
    });

    test('failing jobs are listed', () {
      expect(
        markdown,
        contains(
          '- **pkg** · Integration · '
          '[Web Linux x64 Chrome dart2js](https://x/Web Linux x64 Chrome '
          'dart2js) · 5m ago, `main` `abcdef0`',
        ),
      );
    });

    test('a failed run with only cancelled jobs is listed', () {
      final md = renderDashboard([
        PackageStatus(
          const DashboardPackage(repo: 'o/q', tests: ['integration.yml']),
          'main',
          {
            'integration.yml': _run(
              'integration.yml',
              [_job('Linux x64'), _job('macOS ARM64', 'cancelled')],
              now,
              conclusion: 'failure',
            ),
          },
        ),
      ], now);
      expect(md, isNot(contains('## Failing')));
      expect(md, contains('## Cancelled'));
      expect(
        md,
        contains(
          '- **q** · Integration · [macOS ARM64](https://x/macOS ARM64)',
        ),
      );
    });

    test('a failed run with notes lists them under Failing', () {
      final md = renderDashboard([
        PackageStatus(
          const DashboardPackage(
            repo: 'o/u',
            tests: [],
            checks: ['upstream_watch.yml'],
          ),
          'main',
          {
            'upstream_watch.yml': _run('upstream_watch.yml', [
              _job('watch / watch', 'failure'),
            ], now).withNotes(['FFmpeg 9.0 → 9.0.2', 'zlib 1.3.1 → 1.3.2']),
          },
        ),
      ], now);
      expect(
        md,
        contains(
          '- **u** · Integration · [FFmpeg 9.0 → 9.0.2, zlib 1.3.1 → 1.3.2]'
          '(https://x/watch / watch)',
        ),
      );
    });

    test('failed and cancelled runs are in separate sections', () {
      final md = renderDashboard([
        PackageStatus(
          const DashboardPackage(repo: 'o/f', tests: ['integration.yml']),
          'main',
          {
            'integration.yml': _run('integration.yml', [
              _job('Linux x64', 'failure'),
              _job('macOS ARM64', 'cancelled'),
            ], now),
          },
        ),
        PackageStatus(
          const DashboardPackage(repo: 'o/c', tests: ['integration.yml']),
          'main',
          {
            'integration.yml': _run(
              'integration.yml',
              [_job('Linux x64'), _job('macOS ARM64', 'cancelled')],
              now,
              conclusion: 'failure',
            ),
          },
        ),
      ], now);
      final failing = md.substring(
        md.indexOf('## Failing'),
        md.indexOf('## Cancelled'),
      );
      final cancelled = md.substring(
        md.indexOf('## Cancelled'),
        md.indexOf('| Package |'),
      );
      expect(
        failing,
        contains(
          '- **f** · Integration · [Linux x64](https://x/Linux x64) · '
          '1 cancelled',
        ),
      );
      expect(failing, isNot(contains('**c**')));
      expect(cancelled, contains('- **c** · Integration · [macOS ARM64]'));
      expect(cancelled, isNot(contains('**f**')));
      // Updated, then Failing and Cancelled, then the table; the refresh
      // note last.
      expect(md, isNot(contains('packages maintained')));
      expect(md.indexOf('Updated '), lessThan(md.indexOf('## Failing')));
      expect(md.indexOf('## Cancelled'), lessThan(md.indexOf('| Package |')));
      expect(md.indexOf('## pub.dev'), lessThan(md.indexOf('GitHub runs')));
      expect(md.trimRight(), endsWith('actions/workflows/dashboard.yml).'));
    });

    test(
      'Unit holds every job of the unit workflow that names no platform',
      () {
        final md = renderDashboard([
          PackageStatus(
            const DashboardPackage(repo: 'o/p', tests: ['check_and_lint.yml']),
            'main',
            {
              'check_and_lint.yml': _run('check_and_lint.yml', [
                _job('Rustfmt'),
                _job('Rust (ubuntu-latest, stable)', 'failure'),
                _job('Linux x64'),
              ], now),
            },
          ),
        ], now);
        final cells = md
            .split('| Package |')
            .last
            .split('\n')
            .firstWhere((line) => line.startsWith('| [p]('))
            .let(_cells);
        expect(cells[1], contains('"Rustfmt"'));
        expect(cells[1], contains('"Rust (ubuntu-latest, stable)"'));
        // A job that names a platform keeps its column.
        expect(cells[1], isNot(contains('Linux x64')));
        expect(md, isNot(contains('[✅ Rustfmt]')));
      },
    );

    test('a pipe in a name does not break the table', () {
      final md = renderDashboard([
        PackageStatus(const DashboardPackage(repo: 'o/p'), 'main', {
          'unit.yml': _run('unit.yml', [_job('a | b')], now),
        }),
      ], now);
      expect(md, contains(r'a \| b'));
    });
  });

  group('readDashboardConfig', () {
    test('defaults and overrides', () {
      final packages = readDashboardConfig('''
packages:
  - repo: Telosnex/a
  - repo: Telosnex/b
    tests: [test.yml]
''');
      expect(packages[0].tests, ['unit.yml', 'integration.yml']);
      expect(packages[0].releases, ['kiln_release.yml']);
      expect(packages[1].tests, ['test.yml']);
      expect(packages[1].name, 'b');
    });

    test('rejects an entry without repo', () {
      expect(
        () => readDashboardConfig('packages:\n  - tests: [a.yml]\n'),
        throwsFormatException,
      );
    });
  });

  group('adoption', () {
    test('pubspecUsesKiln', () {
      expect(
        pubspecUsesKiln('name: a\ndev_dependencies:\n  kiln: ^1.0.0\n'),
        isTrue,
      );
      expect(
        pubspecUsesKiln('name: a\ndependencies:\n  kiln:\n    git: x\n'),
        isTrue,
      );
      expect(
        pubspecUsesKiln('name: a\ndependencies:\n  kilns: any\n'),
        isFalse,
      );
      expect(pubspecUsesKiln('name: a\n# kiln: later\n'), isFalse);
    });

    test('workflowUsesCiTools', () {
      expect(
        workflowUsesCiTools(
          '      - uses: Telosnex/telosnex_ci_tools/actions/setup-flutter@abc\n',
        ),
        isTrue,
      );
      expect(
        workflowUsesCiTools(
          '    uses: Telosnex/telosnex_ci_tools/.github/workflows/k.yml@abc\n',
        ),
        isTrue,
      );
      expect(
        workflowUsesCiTools('# see Telosnex/telosnex_ci_tools/actions\n'),
        isFalse,
      );
    });

    test('renderPackages: adopted rows by name, the rest pending', () {
      PackageStatus status(String repo, {bool kiln = false, bool ci = false}) =>
          PackageStatus(
            DashboardPackage(repo: repo),
            'main',
            const {},
            usesKiln: kiln,
            usesCiTools: ci,
          );
      final md = renderPackages([
        status('o/zeta', ci: true),
        status('o/alpha', kiln: true, ci: true),
        status('o/later'),
      ]);
      final rows = md.split('\n').where((l) => l.startsWith('| [')).toList();
      expect(rows, [
        '| [alpha](https://github.com/o/alpha) | ✅ | ✅ |',
        '| [zeta](https://github.com/o/zeta) | — | ✅ |',
      ]);
      expect(
        md,
        contains(
          'Not on the default branch yet: [later](https://github.com/o/later).',
        ),
      );
      expect(md, isNot(contains('Updated')));
    });
  });

  test('other cells: one blank-headed cell each, in alphabetical order; '
      'check and release workflows with age, a release with its branch', () {
    final now = DateTime.utc(2026, 1, 2);
    DashboardRun run(String file, String name, String branch, Duration ago) =>
        DashboardRun(
          workflowFile: file,
          workflowName: name,
          branch: branch,
          sha: 'abcdef0123456789',
          event: 'push',
          conclusion: 'success',
          url: 'https://x/run/$file',
          finishedAt: now.subtract(ago),
          jobs: const [],
        );
    final md = renderDashboard([
      PackageStatus(
        const DashboardPackage(
          repo: 'o/a',
          checks: ['kiln_check.yml', 'upstream_watch.yml'],
        ),
        'main',
        {
          'integration.yml': _run('integration.yml', [
            _job('Linux x64'),
            _job('desktop / windows'),
          ], now),
          'kiln_check.yml': run(
            'kiln_check.yml',
            'Kiln check',
            'main',
            const Duration(hours: 2),
          ),
          'kiln_release.yml': run(
            'kiln_release.yml',
            'Kiln release',
            'v1.2.0',
            const Duration(days: 3),
          ),
        },
      ),
      PackageStatus(
        const DashboardPackage(repo: 'o/b', checks: [], releases: []),
        'main',
        const {},
      ),
    ], now);
    expect(md, isNot(contains('## Workflows')));
    expect(md, isNot(contains('## Test cells')));
    final table = md.split('| Package |').last.split('\n');
    List<String> cellsOf(String name) =>
        _cells(table.firstWhere((line) => line.startsWith('| [$name](')));
    final a = cellsOf('a');
    // Unit, Linux x64, then the other cells in alphabetical order of their
    // label, ignoring case.
    expect(a[3], startsWith('[✅ desktop / windows]'));
    expect(
      a[4],
      '[✅ Kiln check](https://x/run/kiln_check.yml "kiln_check.yml") 2h',
    );
    expect(
      a[5],
      '[✅ Kiln release](https://x/run/kiln_release.yml "kiln_release.yml") '
      '3d `v1.2.0`',
    );
    // A check with no finished run yet.
    expect(a[6], 'upstream_watch.yml: no run |');
    // A package with none: empty cells.
    expect(cellsOf('b').sublist(3), everyElement(anyOf('', ' |', ' ')));
  });

  group('pub.dev section', () {
    final now = DateTime.utc(2026, 1, 10);
    PackageStatus status(String repo, {String? current}) => PackageStatus(
      DashboardPackage(repo: repo, checks: const [], releases: const []),
      'main',
      const {},
      usesCiTools: true,
      currentRepo: current,
    );
    PubPackage pub(String name, String? repo, int daysAgo, [PubDrift? d]) =>
        PubPackage(
          name: name,
          version: '1.0.$daysAgo',
          published: now.subtract(Duration(days: daysAgo)),
          repo: repo,
          drift: d,
        );
    List<String> rowsOf(String md, String name) => [
      for (final line in md.split('## pub.dev').last.split('\n'))
        if (line.startsWith('| [$name](')) line,
    ];

    test('a row per repository, even with no package; a row per package, '
        'matched ignoring case and by the current name after a rename', () {
      final md = renderDashboard(
        [
          status('Telosnex/mono'),
          status('Telosnex/libmonet', current: 'Telosnex/monet_ui'),
          status('Telosnex/none'),
        ],
        now,
        published: [
          pub(
            'mono_b',
            'telosnex/Mono',
            2,
            const PubDrift(
              branch: 'main',
              directory: 'b',
              changed: ['lib/b.dart'],
              added: ['lib/new.dart'],
              onlyPublished: ['lib/gone.dart'],
            ),
          ),
          pub(
            'mono_a',
            'Telosnex/mono',
            3,
            const PubDrift(branch: 'main', directory: ''),
          ),
          pub('monet_ui', 'Telosnex/monet_ui', 4),
          pub('stray', null, 1),
        ],
      );
      expect(md.indexOf('## pub.dev'), greaterThan(md.indexOf('| Package |')));
      expect(md.split('## pub.dev').first, isNot(contains('pub.dev/packages')));
      final mono = rowsOf(md, 'mono');
      expect(mono, hasLength(2));
      expect(
        mono[0],
        endsWith(
          '| [![mono_a](https://img.shields.io/pub/v/mono_a?label=mono_a)]'
          '(https://pub.dev/packages/mono_a) '
          '[![pub points](https://img.shields.io/pub/points/mono_a)]'
          '(https://pub.dev/packages/mono_a/score) | 3d | ✅ same |',
        ),
      );
      expect(
        mono[1],
        contains(
          '[⚠️ 1 changed · 1 new · 1 only on pub.dev]'
          '(https://github.com/Telosnex/mono/commits/main?since='
          '2026-01-08T00:00:00.000Z&path=b "Changed: lib/b.dart. New: '
          'lib/new.dart. Only on pub.dev: lib/gone.dart.")',
        ),
      );
      expect(rowsOf(md, 'libmonet').single, contains('pub/v/monet_ui'));
      expect(
        rowsOf(md, 'none').single,
        '| [none](https://github.com/Telosnex/none) | — | | |',
      );
    });

    test('pubRepositories: rows for packages not in the table', () {
      final md = renderDashboard(
        [status('Telosnex/mono')],
        now,
        published: [pub('kiln', 'Telosnex/kiln', 1)],
        pubRepositories: [status('Telosnex/mono'), status('Telosnex/kiln')],
      );
      expect(md.split('## pub.dev').first, isNot(contains('[kiln]')));
      expect(rowsOf(md, 'kiln').single, contains('pub/v/kiln'));
      expect(rowsOf(md, 'mono').single, contains('| — |'));
    });

    test('a warning when pub.dev could not be read', () {
      final md = renderDashboard(
        [status('Telosnex/mono')],
        now,
        published: null,
      );
      expect(
        md.split('## pub.dev').last,
        contains('⚠️ pub.dev could not be read.'),
      );
    });

    test('gitHubRepoOf', () {
      expect(
        gitHubRepoOf('https://github.com/Telosnex/fonnx'),
        'Telosnex/fonnx',
      );
      expect(
        gitHubRepoOf(
          'https://github.com/Telosnex/highlight_fork/tree/master/x',
        ),
        'Telosnex/highlight_fork',
      );
      expect(gitHubRepoOf('git@github.com:o/r.git'), 'o/r');
      expect(gitHubRepoOf('https://example.com'), isNull);
      expect(gitHubRepoOf(null), isNull);
    });

    test('gitBlobHash is git hash-object', () {
      // printf 'hello\n' | git hash-object --stdin
      expect(
        gitBlobHash(utf8.encode('hello\n')),
        'ce013625030ba8dba906f756967f9e9ca394464a',
      );
    });

    test('readTarGz reads files, long names, and skips directories', () async {
      final dir = Directory.systemTemp.createTempSync('tar_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final long = 'd/${'x' * 120}.dart';
      File('${dir.path}/$long').createSync(recursive: true);
      File('${dir.path}/$long').writeAsStringSync('long');
      File('${dir.path}/pubspec.yaml').writeAsStringSync('name: p\n');
      final r = await Process.run(
        'tar',
        ['czf', 'out.tgz', 'pubspec.yaml', 'd'],
        workingDirectory: dir.path,
        // macOS tar adds ._ AppleDouble files otherwise.
        environment: {'COPYFILE_DISABLE': '1'},
      );
      expect(r.exitCode, 0, reason: '${r.stderr}');
      final files = readTarGz(File('${dir.path}/out.tgz').readAsBytesSync());
      expect(files.keys, unorderedEquals(['pubspec.yaml', long]));
      expect(utf8.decode(files[long]!), 'long');
    });

    test('comparePublished: picks the matching package directory; counts '
        'changed, new under lib/bin/hook, and only-published; skips '
        'submodules, symlinks, dotfiles and nested packages', () {
      Map<String, Object?> blob(String path, String sha) => {
        'path': path,
        'type': 'blob',
        'mode': '100644',
        'sha': sha,
      };
      final drift = comparePublished(
        {
          'pubspec.yaml': 'p1',
          'lib/a.dart': 'a1',
          'lib/b.dart': 'b1',
          'lib/gone.dart': 'g1',
          'src/vendor/x.c': 'x1',
          'lib/link.dart': 'l1',
        },
        [
          blob('pubspec.yaml', 'root'),
          blob('pkg/pubspec.yaml', 'p1'),
          blob('pkg/lib/a.dart', 'a1'),
          blob('pkg/lib/b.dart', 'b2'),
          blob('pkg/lib/new.dart', 'n1'),
          blob('pkg/lib/.hidden.dart', 'h1'),
          blob('pkg/tool/new.dart', 't1'),
          blob('pkg/example/pubspec.yaml', 'e1'),
          blob('pkg/example/lib/main.dart', 'm1'),
          {'path': 'pkg/src/vendor', 'type': 'commit', 'sha': 's'},
          {
            'path': 'pkg/lib/link.dart',
            'type': 'blob',
            'mode': '120000',
            'sha': 'l2',
          },
        ],
        'main',
      );
      expect(drift.directory, 'pkg');
      expect(drift.changed, ['lib/b.dart']);
      expect(drift.added, ['lib/new.dart']);
      expect(drift.onlyPublished, ['lib/gone.dart']);
    });
  });

  group('updatedAt', () {
    test('daylight time', () {
      expect(
        updatedAt(DateTime.utc(2026, 10, 29, 10, 11)),
        '2026-10-29 3:11 AM PDT (10:11 AM UTC)',
      );
    });
    test('standard time, across midnight', () {
      expect(
        updatedAt(DateTime.utc(2026, 12, 1, 5, 30)),
        '2026-11-30 9:30 PM PST (5:30 AM UTC)',
      );
    });
    test('the switches', () {
      // 2026: 8 March 10:00 UTC and 1 November 09:00 UTC.
      expect(updatedAt(DateTime.utc(2026, 3, 8, 9, 59)), contains('PST'));
      expect(updatedAt(DateTime.utc(2026, 3, 8, 10)), contains('PDT'));
      expect(updatedAt(DateTime.utc(2026, 11, 1, 8, 59)), contains('PDT'));
      expect(updatedAt(DateTime.utc(2026, 11, 1, 9)), contains('PST'));
    });
  });

  test('renderDashboard: packages in alphabetical order', () {
    PackageStatus status(String repo) =>
        PackageStatus(DashboardPackage(repo: repo), 'main', const {});
    final md = renderDashboard([
      status('o/zxing'),
      status('o/Fonnx'),
      status('o/audio'),
    ], DateTime.utc(2026));
    final a = md.indexOf('[audio]');
    final f = md.indexOf('[Fonnx]');
    final z = md.indexOf('[zxing]');
    expect(a, greaterThan(-1));
    expect(a < f && f < z, isTrue);
  });

  test('neededJobNames: the name of each needed job, or its id', () {
    const workflow = '''
jobs:
  models:
    name: Models
  web-files:
    runs-on: ubuntu-24.04
  android-universal:
    name: Android universal build
  linux:
    name: Linux x64
    needs: models
  web:
    name: Web Linux x64 Chrome dart2js
    needs: [models, web-files]
''';
    expect(neededJobNames(workflow), {'Models', 'web-files'});
    expect(neededJobNames(': ['), isEmpty);
  });

  group('setup jobs', () {
    final now = DateTime.utc(2026, 1, 2);
    String rowOf(List<DashboardJob> jobs) {
      final md = renderDashboard([
        PackageStatus(
          const DashboardPackage(
            repo: 'Telosnex/pkg',
            tests: ['unit.yml', 'integration.yml'],
          ),
          'main',
          {
            'unit.yml': _run('unit.yml', [_job('Unit')], now),
            'integration.yml': DashboardRun(
              workflowFile: 'integration.yml',
              workflowName: 'Integration',
              branch: 'main',
              sha: 'abcdef0123456789',
              event: 'push',
              conclusion: 'success',
              url: 'https://x/run/integration.yml',
              finishedAt: now,
              jobs: [_job('Linux x64'), ...jobs],
              setupJobs: const {'Web files'},
            ),
          },
        ),
      ], now);
      return md
          .split('| Package |')
          .last
          .split('\n')
          .firstWhere((l) => l.startsWith('| [pkg]('));
    }

    test('one that passed is not shown', () {
      final row = rowOf([_job('Web files'), _job('Android universal build')]);
      expect(row, isNot(contains('Web files')));
      // Not needed by another job: a test, shown.
      expect(row, contains('Android universal build'));
    });

    test('one that failed is shown', () {
      expect(rowOf([_job('Web files', 'failure')]), contains('Web files'));
    });
  });

  test('kilnWorkingDirectories: the Kiln calls only', () {
    const workflow = '''
jobs:
  kiln:
    uses: Telosnex/telosnex_ci_tools/.github/workflows/kiln_check.yml@abc
    with:
      working-directory: ./super_native_extensions/
  other:
    uses: Telosnex/telosnex_ci_tools/.github/workflows/other.yml@abc
    with:
      working-directory: nope
  root:
    uses: Telosnex/telosnex_ci_tools/.github/workflows/kiln_release.yml@abc
''';
    expect(kilnWorkingDirectories(workflow), {'super_native_extensions'});
    expect(kilnWorkingDirectories(': ['), isEmpty);
  });
}
