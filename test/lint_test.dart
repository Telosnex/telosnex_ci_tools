import 'dart:io';

import 'package:telosnex_ci_tools/src/lint.dart';
import 'package:test/test.dart';

const _checkout =
    'actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1';

List<String> _rules(String path, String text) => [
  for (final f in lintWorkflow(path, text)) f.rule,
];

String _workflow({
  String name = 'Native release',
  String extra = '',
  String job = '',
}) =>
    '''
name: $name
on: push
permissions:
  contents: read
$extra
jobs:
  build:
    runs-on: ubuntu-24.04
    timeout-minutes: 10
    steps:
      - uses: $_checkout
$job''';

void main() {
  test('a workflow that obeys every rule has no findings', () {
    expect(lintWorkflow('native_release.yml', _workflow()), isEmpty);
  });

  test('file-name', () {
    expect(_rules('native-release.yml', _workflow()), ['file-name']);
    expect(_rules('native_release.yaml', _workflow()), ['file-name']);
  });

  group('name', () {
    test('sentence case', () {
      expect(nameProblem('Native release'), isNull);
      expect(nameProblem('CUDA pack'), isNull);
      expect(nameProblem('CI'), isNull);
      expect(nameProblem('native release'), isNotNull);
      expect(nameProblem('Native Release'), isNotNull);
      expect(nameProblem('Native release.'), isNotNull);
    });

    test('matches the file name', () {
      expect(nameForFile('native_release.yml'), 'Native release');
      expect(_rules('cuda_pack.yml', _workflow(name: 'CUDA pack')), isEmpty);
      expect(
        _rules('kiln_check.yml', _workflow(name: 'Check prebuilt files')),
        ['name-matches-file'],
      );
    });
  });

  group('matrix', () {
    final text = _workflow(job: '').replaceFirst(
      '    timeout-minutes: 10\n',
      '    timeout-minutes: 10\n'
          '    strategy:\n'
          '      matrix:\n'
          '        include:\n'
          '          - { name: Linux x64, runner: ubuntu-24.04 }\n',
    );

    test('no-matrix', () {
      expect(_rules('native_release.yml', text), ['no-matrix']);
    });

    test('allowed in telosnex_ci_tools', () {
      expect(
        lintWorkflow('native_release.yml', text, allowMatrix: true),
        isEmpty,
      );
    });

    test('anchors are fine', () {
      final anchored = _workflow(
        job: '''
  other:
    runs-on: ubuntu-24.04
    timeout-minutes: 10
    steps: *steps
''',
      ).replaceFirst('    steps:\n', '    steps: &steps\n');
      expect(_rules('native_release.yml', anchored), isEmpty);
    });
  });

  test('no-merge-key', () {
    final text = _workflow(
      job: '''
  other:
    <<: *defaults
    steps: []
''',
    ).replaceFirst('  build:\n', '  build: &defaults\n');
    expect(_rules('native_release.yml', text), contains('no-merge-key'));
  });

  test('action files must parse', () {
    expect(
      lintAction('a/action.yml', 'name: A\nruns:\n  using: composite\n'),
      isEmpty,
    );
    final bad = lintAction(
      'a/action.yml',
      'inputs:\n  x:\n    description: The name. Empty: the job id.\n',
    );
    expect([for (final f in bad) f.rule], ['yaml']);
  });

  test('a job name with an arch or a distribution is in the form', () {
    expect(jobNameProblem('Debian 13 ARM64 WPE SDK'), isNotNull);
    expect(jobNameProblem('Ubuntu build'), isNotNull);
    expect(jobNameProblem('Linux ARM64 Debian 13 WPE SDK'), isNull);
    expect(jobNameProblem('Publish WPE SDK'), isNull);
  });

  test('permissions', () {
    final text = _workflow().replaceFirst(
      'permissions:\n  contents: read\n',
      '',
    );
    expect(_rules('native_release.yml', text), ['permissions']);
  });

  test('timeout', () {
    final text = _workflow().replaceFirst('    timeout-minutes: 10\n', '');
    expect(_rules('native_release.yml', text), ['timeout']);
  });

  group('pinned-uses', () {
    test('a tag is not a pin', () {
      final text = _workflow().replaceFirst(_checkout, 'actions/checkout@v5');
      expect(_rules('native_release.yml', text), ['pinned-uses']);
    });

    test('a pin needs a version comment', () {
      final text = _workflow().replaceFirst(' # v7.0.1', '');
      expect(_rules('native_release.yml', text), ['pinned-uses']);
    });

    test('a branch is not a version comment', () {
      final text = _workflow().replaceFirst(' # v7.0.1', ' # main');
      expect(_rules('native_release.yml', text), ['pinned-uses']);
    });

    test('# self is the version of pin_self, for this repository only', () {
      const self =
          '      - uses: Telosnex/telosnex_ci_tools/actions/setup-flutter@'
          '0123456789012345678901234567890123456789 # self\n';
      expect(_rules('native_release.yml', _workflow(job: self)), isEmpty);
      final other = self.replaceFirst(
        'Telosnex/telosnex_ci_tools/actions/setup-flutter',
        'actions/setup-node',
      );
      expect(_rules('native_release.yml', _workflow(job: other)), [
        'pinned-uses',
      ]);
    });

    test('a version comment may say more after the version', () {
      final text = _workflow().replaceFirst(' # v7.0.1', ' # v5 (Node 24)');
      expect(_rules('native_release.yml', text), isEmpty);
    });

    test('local actions need no pin', () {
      final text = _workflow(job: '      - uses: ./actions/setup-flutter\n');
      expect(_rules('native_release.yml', text), isEmpty);
    });
  });

  test('setup-flutter', () {
    final text = _workflow(
      job: '''
      - run: git clone -q --depth 1 --branch 3.47.1 https://github.com/flutter/flutter.git
''',
    );
    expect(_rules('native_release.yml', text), ['setup-flutter']);
  });

  test('shared-concurrency', () {
    final text =
        '''
name: Native release
on: push
permissions:
  contents: write
concurrency:
  group: native-release
jobs:
  kiln-release:
    uses: $selfRepository/.github/workflows/kiln_release.yml@3d3c42e5aac5ba805825da76410c181273ba90b1 # v1.0.0
''';
    expect(_rules('native_release.yml', text), ['shared-concurrency']);
  });

  group('allowed-actions', () {
    for (final sub in ['restore', 'save']) {
      test('actions/cache/$sub', () {
        final text = _workflow(
          job:
              '      - uses: actions/cache/$sub@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6.1.0\n',
        );
        expect(_rules('native_release.yml', text), ['allowed-actions']);
      });
    }

    test('actions/cache', () {
      final text = _workflow(
        job:
            '      - uses: actions/cache@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6.1.0\n',
      );
      expect(_rules('native_release.yml', text), isEmpty);
    });
  });

  group('job-defaults-shell', () {
    const workflowDefaults = 'defaults:\n  run:\n    shell: bash\n';
    String withJobDefaults(String jobDefaults) =>
        _workflow(extra: workflowDefaults).replaceFirst(
          '    timeout-minutes: 10\n',
          '    timeout-minutes: 10\n$jobDefaults',
        );

    test('job defaults without the shell', () {
      final text = withJobDefaults(
        '    defaults:\n      run:\n        working-directory: pkg\n',
      );
      expect(_rules('native_release.yml', text), ['job-defaults-shell']);
    });

    test('job defaults with the shell', () {
      final text = withJobDefaults(
        '    defaults:\n      run:\n        shell: bash\n        working-directory: pkg\n',
      );
      expect(_rules('native_release.yml', text), isEmpty);
    });

    test('an alias of job defaults with the shell', () {
      final text =
          '''
name: Native release
on: push
permissions:
  contents: read
$workflowDefaults
jobs:
  a:
    runs-on: ubuntu-24.04
    timeout-minutes: 10
    defaults: &d
      run:
        shell: bash
        working-directory: pkg
    steps:
      - run: true
  b:
    runs-on: ubuntu-24.04
    timeout-minutes: 10
    defaults: *d
    steps:
      - run: true
''';
      expect(_rules('native_release.yml', text), isEmpty);
    });

    test('no workflow shell: no finding', () {
      final text = _workflow().replaceFirst(
        '    timeout-minutes: 10\n',
        '    timeout-minutes: 10\n    defaults:\n      run:\n        working-directory: pkg\n',
      );
      expect(_rules('native_release.yml', text), isEmpty);
    });
  });

  group('flutter-bootstrap', () {
    List<String> rules(String html) => [
      for (final f in lintWebIndex('example/web/index.html', html)) f.rule,
    ];

    test('the legacy loader', () {
      expect(
        rules('''
<head>
  <script src="flutter.js" defer></script>
</head>
<body>
  <script>
    window.addEventListener('load', function () {
      _flutter.loader.loadEntrypoint({});
    });
  </script>
</body>
'''),
        ['flutter-bootstrap'],
      );
      expect(
        rules(
          '<script src="main.dart.js" type="application/javascript"></script>',
        ),
        ['flutter-bootstrap'],
      );
    });

    test('flutter_bootstrap.js', () {
      expect(
        rules(
          '<body>\n  <script src="flutter_bootstrap.js" async></script>\n</body>',
        ),
        isEmpty,
      );
    });

    test('not a Flutter page', () {
      expect(rules('<html><body>Hello</body></html>'), isEmpty);
    });
  });

  group('tee-pipefail', () {
    String step(String run, {String shell = ''}) =>
        '      - run: $run\n${shell.isEmpty ? '' : '        shell: $shell\n'}';

    test('a pipe into tee in the default shell', () {
      final text = _workflow(job: step('flutter drive | tee drive.log'));
      expect(_rules('native_release.yml', text), ['tee-pipefail']);
    });

    test('shell: bash on the step', () {
      final text = _workflow(
        job: step('flutter drive | tee drive.log', shell: 'bash'),
      );
      expect(_rules('native_release.yml', text), isEmpty);
    });

    test('shell: bash in the workflow defaults', () {
      final text = _workflow(
        extra: 'defaults:\n  run:\n    shell: bash\n',
        job: step('flutter drive 2>&1 | tee drive.log'),
      );
      expect(_rules('native_release.yml', text), isEmpty);
    });

    test('set -o pipefail in the script', () {
      final text = _workflow(
        job:
            '      - run: |\n          set -o pipefail\n          flutter drive | tee drive.log\n',
      );
      expect(_rules('native_release.yml', text), isEmpty);
    });

    test('a pipe into another command', () {
      final text = _workflow(job: step('ls | head -3'));
      expect(_rules('native_release.yml', text), isEmpty);
    });
  });

  group('drive-test-widgets', () {
    List<String> rules(String dart) => [
      for (final f in lintDriveTarget('integration_test/a_test.dart', dart))
        f.rule,
    ];

    test('test() in a driven file', () {
      expect(
        rules(
          "void main() {\n  test('a', () {});\n  testWidgets('b', (t) async {});\n}\n",
        ),
        ['drive-test-widgets'],
      );
    });

    test('testWidgets only', () {
      expect(
        rules(
          "void main() {\n  group('g', () {\n    testWidgets('b', (t) async {});\n  });\n}\n",
        ),
        isEmpty,
      );
    });

    test('lintRepository finds the --target of flutter drive', () {
      final repo = Directory.systemTemp.createTempSync('lint_drive');
      addTearDown(() => repo.deleteSync(recursive: true));
      File('${repo.path}/.github/workflows/web_test.yml')
        ..createSync(recursive: true)
        ..writeAsStringSync(
          _workflow(
            name: 'Web test',
            extra: 'defaults:\n  run:\n    shell: bash\n',
            job:
                '      - run: flutter drive --driver test_driver/d.dart --target integration_test/web_test.dart\n'
                '        working-directory: example\n',
          ),
        );
      File('${repo.path}/example/integration_test/web_test.dart')
        ..createSync(recursive: true)
        ..writeAsStringSync("void main() {\n  test('a', () {});\n}\n");
      expect(
        [
          for (final f in lintRepository(repo.path))
            '${f.path}:${f.line} ${f.rule}',
        ],
        ['example/integration_test/web_test.dart:2 drive-test-widgets'],
      );
    });

    test('the -t of another command is not a drive target', () {
      final repo = Directory.systemTemp.createTempSync('lint_drive');
      addTearDown(() => repo.deleteSync(recursive: true));
      File('${repo.path}/.github/workflows/web_test.yml')
        ..createSync(recursive: true)
        ..writeAsStringSync(
          _workflow(
            name: 'Web test',
            extra: 'defaults:\n  run:\n    shell: bash\n',
            job:
                '      - run: |\n'
                '          flutter build ios --simulator \\\n'
                '            -t integration_test/native_test.dart\n'
                '          flutter drive --driver test_driver/d.dart \\\n'
                '            --target integration_test/web_test.dart\n'
                '        working-directory: example\n',
          ),
        );
      for (final name in ['native_test.dart', 'web_test.dart']) {
        File('${repo.path}/example/integration_test/$name')
          ..createSync(recursive: true)
          ..writeAsStringSync("void main() {\n  test('a', () {});\n}\n");
      }
      expect(
        [
          for (final f in lintRepository(repo.path))
            '${f.path}:${f.line} ${f.rule}',
        ],
        ['example/integration_test/web_test.dart:2 drive-test-widgets'],
      );
    });
  });

  group('telosnex_ci_tools in a package', () {
    final a = 'a' * 40, b = 'b' * 40;
    String uses(String action, String sha) =>
        '      - uses: Telosnex/telosnex_ci_tools/actions/$action@$sha # v1.0.0\n';
    List<String> lintFiles(Map<String, String> workflows) {
      final repo = Directory.systemTemp.createTempSync('lint_tools');
      addTearDown(() => repo.deleteSync(recursive: true));
      for (final MapEntry(:key, :value) in workflows.entries) {
        File('${repo.path}/.github/workflows/$key')
          ..createSync(recursive: true)
          ..writeAsStringSync(value);
      }
      return [
        for (final f in lintRepository(repo.path))
          if (f.rule == 'one-tools-version' || f.rule == 'lint-step')
            '${f.path}:${f.line} ${f.rule}',
      ];
    }

    test('one commit and the lint step: no findings', () {
      expect(
        lintFiles({
          'unit.yml': _workflow(
            name: 'Unit',
            job: uses('setup-flutter', a) + uses('lint', a),
          ),
          'integration.yml': _workflow(
            name: 'Integration',
            job: uses('setup-flutter', a),
          ),
        }),
        isEmpty,
      );
    });

    test('a second commit is flagged where it is used', () {
      expect(
        lintFiles({
          'unit.yml': _workflow(
            name: 'Unit',
            job: uses('setup-flutter', a) + uses('lint', a),
          ),
          'kiln_check.yml': _workflow(
            name: 'Kiln check',
            job: uses('setup-flutter', b),
          ),
        }),
        [startsWith('.github/workflows/unit.yml:')],
      );
    });

    test('unit.yml without the lint action', () {
      expect(
        lintFiles({
          'unit.yml': _workflow(name: 'Unit', job: uses('setup-flutter', a)),
        }),
        ['.github/workflows/unit.yml:1 lint-step'],
      );
    });

    test('no unit.yml: no lint-step finding', () {
      expect(
        lintFiles({
          'integration.yml': _workflow(
            name: 'Integration',
            job: uses('setup-flutter', a),
          ),
        }),
        isEmpty,
      );
    });
  });

  group('job names', () {
    for (final name in [
      'Windows ARM64',
      'Windows x64',
      'Linux ARM64',
      'macOS ARM64 Metal',
      'iOS ARM64 simulator',
      'Android x64 API 37',
      'Android universal example build',
      'Web Linux ARM64 Chrome',
      'Web Linux x64 Chrome dart2wasm',
      'Web iOS ARM64 Safari',
      'Unit',
      'Web files',
      'Kiln check',
      'Roll BoringSSL',
    ]) {
      test('accepts "$name"', () => expect(jobNameProblem(name), isNull));
    }
    for (final name in [
      'desktop / linux-x64',
      'web / chrome / dart2js',
      'Linux arm64',
      'Web Chrome',
      'MacOS desktop / Chrome',
      'Android emulator',
      'iPhone simulator',
    ]) {
      test('rejects "$name"', () => expect(jobNameProblem(name), isNotNull));
    }
    test('checks matrix names', () {
      const workflow = '''
name: Integration
permissions: {}
jobs:
  desktop:
    name: \${{ matrix.name }}
    timeout-minutes: 5
    strategy:
      matrix:
        include:
          - name: Windows ARM64
          - name: linux-x64
    runs-on: ubuntu-24.04
    steps: []
''';
      final findings = lintWorkflow(
        'integration.yml',
        workflow,
      ).where((f) => f.rule == 'job-name').toList();
      expect(findings, hasLength(1));
      expect(findings.single.message, contains('linux-x64'));
    });
  });
}
