import 'dart:convert';

/// The key of the result counts in `binding.reportData`. The counts are the
/// only report data the driver prints: the rest (screenshots, responses,
/// errors) can hold anything the app saw.
const webTestSummaryKey = 'telosnexWebTestSummary';

/// The prefix of the driver's summary line in the flutter drive output.
const webTestSummaryMarker = 'TELOSNEX_WEB_TEST_SUMMARY: ';

/// The counts of a summary, in order.
const webTestCountKeys = ['passed', 'failed', 'skipped', 'notRun'];

/// The counts of a summary payload (version 1), or null if it is not one.
Map<String, int>? webTestCounts(Object? payload) {
  if (payload is! Map || payload['version'] != 1) return null;
  final counts = <String, int>{};
  for (final key in webTestCountKeys) {
    final value = payload[key];
    if (value is! int || value < 0 || value > 100000) return null;
    counts[key] = value;
  }
  return counts;
}

/// The counts in the report data of a run, or null if the app did not
/// report them (it did not call installWebTestSupport).
Map<String, int>? webTestReportCounts(Object? reportData) =>
    reportData is Map ? webTestCounts(reportData[webTestSummaryKey]) : null;

/// The summary line of [reportData], or null without counts.
String? webTestSummaryLine(Object? reportData) {
  final counts = webTestReportCounts(reportData);
  if (counts == null) return null;
  return '$webTestSummaryMarker${jsonEncode({'version': 1, ...counts})}';
}
