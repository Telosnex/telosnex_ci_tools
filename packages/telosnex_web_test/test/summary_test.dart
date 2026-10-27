import 'package:flutter_test/flutter_test.dart';
import 'package:telosnex_web_test/driver.dart';

void main() {
  const counts = {'passed': 3, 'failed': 1, 'skipped': 0, 'notRun': 2};

  test('reads the counts of version 1', () {
    expect(
      webTestReportCounts({
        webTestSummaryKey: {'version': 1, ...counts},
        'other': 'data',
      }),
      counts,
    );
  });

  test('rejects other payloads', () {
    expect(webTestReportCounts(null), isNull);
    expect(webTestReportCounts({'other': 1}), isNull);
    expect(webTestCounts({'version': 2, ...counts}), isNull);
    expect(webTestCounts({'version': 1, ...counts, 'passed': -1}), isNull);
    expect(webTestCounts({'version': 1, 'passed': 1}), isNull);
  });

  test('the summary line has the counts only', () {
    expect(
      webTestSummaryLine({
        webTestSummaryKey: {'version': 1, ...counts, 'secret': 'x'},
        'secret': 'y',
      }),
      '$webTestSummaryMarker'
      '{"version":1,"passed":3,"failed":1,"skipped":0,"notRun":2}',
    );
  });
}
