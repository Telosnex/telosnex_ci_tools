import 'package:telosnex_ci_tools/src/dashboard.dart';
import 'package:telosnex_ci_tools/src/dashboard_fetch.dart';
import 'package:telosnex_ci_tools/src/job_names.dart';
import 'package:test/test.dart';

DashboardJob _job(String name, [String? conclusion = 'success']) =>
    DashboardJob(name: name, conclusion: conclusion, url: 'https://x/$name');

DashboardRun _run(String file, List<DashboardJob> jobs, DateTime at) =>
    DashboardRun(
      workflowFile: file,
      workflowName: file == 'unit.yml' ? 'Unit' : 'Integration',
      branch: 'main',
      sha: 'abcdef0123456789',
      event: 'push',
      conclusion: jobs.any((j) => j.conclusion == 'failure')
          ? 'failure'
          : 'success',
      url: 'https://x/run/$file',
      finishedAt: at,
      jobs: jobs,
    );

void main() {
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
      const DashboardPackage(repo: 'Telosnex/pkg'),
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
      const DashboardPackage(repo: 'Telosnex/other'),
      'main',
      const {},
    );
    final markdown = renderDashboard([package, empty], now);
    List<String> row(String name, String section) {
      final table = markdown.split('## $section').last;
      return table
          .split('\n')
          .firstWhere(
            (line) =>
                line.startsWith('| $name') || line.startsWith('| [$name]'),
          )
          .split(' | ');
    }

    test('Unit first, a column per cell, then one blank-headed column per '
        'other job', () {
      // pkg has two other jobs: two blank headers, whatever their names.
      expect(
        markdown,
        contains(
          '| Package | Unit | Android x64 | Linux x64 | Web Chrome |   |   |',
        ),
      );
      final cells = row('pkg', 'Test cells');
      expect(cells[1], '[✅](https://x/Unit "Unit")');
      // emulator is the usual way to run Android: in its column.
      expect(cells[2], contains('"Android x64 emulator"'));
      // Only the plain Linux job: fake camera is an extra target.
      expect(cells[3], '[✅](https://x/Linux x64 "Linux x64")');
      // Both compilers in one column, in name order.
      expect(cells[4], startsWith('[❌]'));
      expect(cells[4], contains('dart2js'));
      expect(cells[4].indexOf('dart2js'), lessThan(cells[4].indexOf('wasm')));
      // Extra targets first, then names with no platform; one each.
      expect(cells[5], startsWith('[✅ Linux x64 fake camera]'));
      expect(cells[6], startsWith('[✅ desktop / windows]'));
    });

    test('a package with fewer other jobs leaves the rest empty', () {
      final cells = row('other', 'Test cells');
      expect(cells[5], '');
    });

    test('no job is —', () {
      expect(
        row('other', 'Test cells').sublist(1, 5),
        everyElement(startsWith('—')),
      );
    });

    test('workflow ages', () {
      final cells = row('pkg', 'Workflows');
      expect(cells[1], endsWith(' 2h'));
      expect(cells[2], endsWith(' 5m'));
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
            .split('## Test cells')
            .last
            .split('\n')
            .firstWhere((line) => line.startsWith('| p |'))
            .split(' | ');
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

  test('Workflows: — for a workflow the package lacks, no run for one '
      'with no finished run', () {
    final md = renderDashboard([
      PackageStatus(
        const DashboardPackage(repo: 'o/a', releases: []),
        'main',
        const {},
      ),
      PackageStatus(
        const DashboardPackage(repo: 'o/b', checks: [], releases: []),
        'main',
        const {},
      ),
    ], DateTime.utc(2026));
    final rows = md.split('## Workflows').last.split('\n');
    String cellsOf(String name) =>
        rows.firstWhere((line) => line.startsWith('| [$name]'));
    // unit.yml, integration.yml, kiln_check.yml
    expect(cellsOf('a'), endsWith('| no run | no run | no run |'));
    expect(cellsOf('b'), endsWith('| no run | no run | — |'));
  });

  group('updatedAt', () {
    test('daylight time', () {
      expect(
        updatedAt(DateTime.utc(2026, 10, 29, 10, 11)),
        '2026-10-29 03:11 PDT (10:11 UTC)',
      );
    });
    test('standard time, across midnight', () {
      expect(
        updatedAt(DateTime.utc(2026, 12, 1, 5, 30)),
        '2026-11-30 21:30 PST (05:30 UTC)',
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
