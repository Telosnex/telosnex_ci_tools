import 'package:test/test.dart';

import '../actions/android-arm64-container/run_tests.dart';

void main() {
  group('parseLogcat', () {
    test('reads the tag and message of -v tag lines', () {
      expect(parseLogcat('I/flutter ( 1900): 00:01 +1: a tap counts'), (
        'flutter',
        '00:01 +1: a tap counts',
      ));
      expect(parseLogcat('I/flutter: All tests passed!'), (
        'flutter',
        'All tests passed!',
      ));
      expect(parseLogcat('E/AndroidRuntime( 42): FATAL EXCEPTION: main'), (
        'AndroidRuntime',
        'FATAL EXCEPTION: main',
      ));
    });

    test('keeps an empty message', () {
      expect(parseLogcat('I/flutter ( 1900): '), ('flutter', ''));
    });

    test('ignores other lines', () {
      expect(parseLogcat('--------- beginning of main'), isNull);
    });
  });

  test('resultOf reads the reporter\'s last line', () {
    expect(resultOf('00:03 +2: All tests passed!'), Outcome.passed);
    expect(resultOf('00:03 +1 -1: Some tests failed.'), Outcome.failed);
    expect(resultOf('00:00 ~2: All tests skipped.'), Outcome.skipped);
    expect(resultOf('00:01 +1: a tap counts'), isNull);
  });

  test('countsOf reads the progress counts', () {
    expect(countsOf('00:01 +1: a tap counts'), (
      passed: 1,
      skipped: 0,
      failed: 0,
    ));
    expect(countsOf('01:12 +3 ~1 -2: fails [E]'), (
      passed: 3,
      skipped: 1,
      failed: 2,
    ));
    expect(countsOf('Expected: <2>'), isNull);
  });

  test('Progress does not count setUpAll and tearDownAll', () {
    final progress = Progress();
    for (final line in [
      '00:00 +0: (setUpAll)',
      '00:00 +1: passes',
      '00:00 +2: fails',
      '00:00 +2 -1: fails [E]',
      'Expected: <2>',
      '00:00 +2 -1: (tearDownAll)',
      '00:00 +3 -1: Some tests failed.',
    ]) {
      progress.add(line);
    }
    expect('$progress', '1 passed, 1 failed');
  });
}
