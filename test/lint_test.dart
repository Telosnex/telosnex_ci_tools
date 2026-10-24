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
}
