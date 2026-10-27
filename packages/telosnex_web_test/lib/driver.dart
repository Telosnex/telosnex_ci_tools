/// The driver half of telosnex_web_test, for test_driver/integration_test.dart:
///
/// ```dart
/// import 'package:telosnex_web_test/driver.dart';
///
/// Future<void> main() => webIntegrationDriver();
/// ```
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_driver/flutter_driver.dart';
import 'package:integration_test/common.dart';

import 'src/console_protocol.dart';
import 'src/console_tail.dart';
import 'src/summary.dart';

export 'src/summary.dart';

/// The environment variable of the console log path. The web-driver action
/// of telosnex_ci_tools sets it, and uploads the file.
const consoleLogEnvironment = 'TELOSNEX_WEB_TEST_CONSOLE';

/// The environment variable of the response file path.
const responseFileEnvironment = 'TELOSNEX_WEB_TEST_RESPONSE';

/// Runs the integration test like integrationDriver(), and:
///
/// - every [pollInterval] while the tests run, appends the page's new console
///   lines to [consoleLog] (installWebTestSupport keeps them), and when the
///   page logged anything new, prints a progress line: the running test and
///   the newest line. A run that hangs or is stopped still leaves its
///   console. A CI watchdog sees output from a slow run that logs, and none
///   from a silent one: in a long silent step, call markWebTestStep now and
///   then, or set [progressEveryPoll] (then the watchdog never fires while
///   the page answers, and the job's timeout-minutes is the limit). The
///   console is read once more at the end;
/// - always writes the report data to [responseFile] (integrationDriver
///   writes it only when all tests passed);
/// - prints the details of each failure, and the result counts of
///   installWebTestSupport. It never prints the rest of the report data;
/// - with [requireTests], fails when the counts show no test that passed or
///   failed: a run that ran nothing does not pass.
///
/// Paths: the argument, else the environment variable ([consoleLogEnvironment],
/// [responseFileEnvironment]), else build/web_console.log and
/// build/integration_response_data.json. Relative to the working directory.
///
/// Exits the process: 0 when all tests passed, 1 otherwise.
Future<Never> webIntegrationDriver({
  Duration timeout = const Duration(hours: 1),
  Duration pollInterval = const Duration(seconds: 30),
  String? consoleLog,
  String? responseFile,
  bool requireTests = true,
  bool progressEveryPoll = false,
}) async {
  final env = Platform.environment;
  final driver = await FlutterDriver.connect();
  final poller = driver is WebFlutterDriver
      ? _ConsolePoller(
          driver,
          ConsoleTail(
            File(
              consoleLog ??
                  env[consoleLogEnvironment] ??
                  'build/web_console.log',
            ),
          ),
        )
      : null;
  final start = DateTime.now();
  String? lastStatus;
  final timer = Timer.periodic(pollInterval, (_) async {
    if (poller == null) return;
    final status = await poller.poll();
    // Only news: a page that stays silent prints nothing, so a CI watchdog
    // (watch's --idle) still stops a run that hangs.
    if (status == lastStatus && !progressEveryPoll) return;
    lastStatus = status;
    final seconds = DateTime.now().difference(start).inSeconds;
    stdout.writeln('[progress ${seconds}s] $status');
  });

  final Response response;
  try {
    response = Response.fromJson(
      await driver.requestData(null, timeout: timeout),
    );
  } finally {
    timer.cancel();
    // The lines since the last poll; also after a timeout.
    final status = await poller?.poll();
    if (poller != null) {
      stdout.writeln(
        'Console: ${poller.tail.total} lines in ${poller.tail.file.path}'
        '${status!.startsWith('page did not answer') ? ' ($status)' : ''}',
      );
    }
  }
  await driver.close();

  File(
      responseFile ??
          env[responseFileEnvironment] ??
          'build/integration_response_data.json',
    )
    ..createSync(recursive: true)
    ..writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(response.data ?? {}),
    );
  for (final failure in response.failureDetails ?? const <Failure>[]) {
    stdout
      ..writeln('FAILED: ${failure.methodName}')
      ..writeln(failure.details);
  }

  var passed = response.allTestsPassed;
  final summary = webTestSummaryLine(response.data);
  final counts = webTestReportCounts(response.data);
  if (summary != null) stdout.writeln(summary);
  if (counts == null) {
    stdout.writeln(
      'Warning: no result counts. Without installWebTestSupport, a failing '
      'plain test(), setUp or tearDown passes.',
    );
  } else if (requireTests && counts['passed']! + counts['failed']! == 0) {
    stdout.writeln('No test ran.');
    passed = false;
  }
  // web-driver of telosnex_ci_tools reads this line.
  stdout.writeln(passed ? 'All tests passed.' : 'Some tests failed.');
  exit(passed ? 0 : 1);
}

/// Polls one at a time: a poll that comes while one runs waits for it.
final class _ConsolePoller {
  _ConsolePoller(this.driver, this.tail);

  final WebFlutterDriver driver;
  final ConsoleTail tail;
  Future<String>? _running;

  Future<String> poll() async {
    while (_running != null) {
      await _running;
    }
    final running = _poll();
    _running = running;
    try {
      return await running;
    } finally {
      _running = null;
    }
  }

  Future<String> _poll() async {
    try {
      // Until it has every line: one answer has at most 5,000.
      while (true) {
        final json = await driver.webDriver
            .execute(pollConsoleScript, [tail.next])
            .timeout(const Duration(seconds: 20));
        final answer = jsonDecode(json as String) as Map<String, Object?>;
        if (!tail.apply(answer)) break;
      }
    } catch (error) {
      return 'page did not answer: $error';
    }
    if (tail.installed != true) {
      return 'the page has no console capture (installWebTestSupport)';
    }
    return 'test ${tail.test.isEmpty ? '(none yet)' : tail.test}, '
        '${tail.total} console lines; last: ${tail.last}';
  }
}
