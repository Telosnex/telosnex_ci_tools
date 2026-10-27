/// The app half of telosnex_web_test: call [installWebTestSupport] at the
/// top of the integration test's main, right after the binding.
///
/// ```dart
/// void main() {
///   final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
///   installWebTestSupport(binding);
///   testWidgets(...);
/// }
/// ```
///
/// Pair it with `package:telosnex_web_test/driver.dart` in test_driver/.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/common.dart';
import 'package:integration_test/integration_test.dart';
// Flutter's own web test runner uses these test_api internals too.
// ignore: implementation_imports
import 'package:test_api/src/backend/group.dart';
// ignore: implementation_imports
import 'package:test_api/src/backend/invoker.dart';
// ignore: implementation_imports
import 'package:test_api/src/backend/live_test.dart';
// ignore: implementation_imports
import 'package:test_api/src/backend/test.dart' as backend;

import 'src/console_stub.dart'
    if (dart.library.js_interop) 'src/console_web.dart'
    as console;
import 'src/summary.dart';

export 'src/summary.dart';

/// Sets up the run for the driver of `package:telosnex_web_test/driver.dart`:
///
/// - Every test's result. integrationDriver's "All tests passed." comes from
///   `binding.results`, which gets failures of testWidgets only: a plain
///   test() that fails, a failing setUp or tearDown, or a test that never ran
///   would pass. Their failures go into `binding.results` too, and the counts
///   (passed, failed, skipped, notRun) into `binding.reportData`.
/// - With [captureConsole], on the web: the page keeps its console lines
///   (console.*, window errors, unhandled rejections) for the driver, which
///   saves them while the tests run, and a `==== test <name>` line starts
///   each test. The console of Web Workers is not in it.
///
/// Call it first, at the root of main: its tearDown and tearDownAll must run
/// after every other one. Calling it twice does no harm to the console, but
/// counts the tests twice.
void installWebTestSupport(
  IntegrationTestWidgetsFlutterBinding binding, {
  bool captureConsole = true,
}) {
  if (captureConsole) {
    console.installConsoleCapture();
    setUp(() => console.markTest(Invoker.current!.liveTest.test.name));
  }
  _installReporting(binding);
}

/// Logs "==== test [label]" to the page console and shows [label] as the
/// running test in the driver's progress lines. installWebTestSupport does it
/// for each test; this marks a step within one.
void markWebTestStep(String label) => console.markTest(label);

/// The console lines that the page still keeps (at most 20,000). Empty off
/// the web or without the capture.
List<String> webTestConsoleLines() => console.consoleLines();

Iterable<backend.Test> _tests(Group group) sync* {
  for (final entry in group.entries) {
    if (entry is Group) {
      yield* _tests(entry);
    } else if (entry is backend.Test) {
      yield entry;
    }
  }
}

void _installReporting(IntegrationTestWidgetsFlutterBinding binding) {
  var declared = <backend.Test>[];
  // Suite.forPlatform clones the declarations, while Flutter's web runner
  // runs the original tree: match by full name, as binding.results does.
  final executed = <String, LiveTest>{};
  setUpAll(() {
    declared = _tests(Invoker.current!.liveTest.suite.group).toList();
  });
  // Root tearDowns run last, and also when a setUp threw.
  tearDown(() {
    final live = Invoker.current!.liveTest;
    executed[live.test.name] = live;
  });
  // Root tearDownAlls run in reverse order: this one after the app's, and
  // before the binding reports allTestsPassed.
  tearDownAll(() {
    final counts = {for (final key in webTestCountKeys) key: 0};
    for (final test in declared) {
      final live = executed[test.name];
      final result = live?.state.result;
      final key = switch (result) {
        .success => 'passed',
        .failure || .error => 'failed',
        .skipped => 'skipped',
        null => test.metadata.skip ? 'skipped' : 'notRun',
      };
      counts[key] = counts[key]! + 1;
      if (result?.isFailing == true) {
        // results is for test code; this library runs only in tests.
        // ignore: invalid_use_of_visible_for_testing_member
        binding.results.putIfAbsent(
          test.name,
          () => Failure(test.name, live!.errors.join('\n')),
        );
      }
    }
    if (counts['notRun']! > 0) {
      // A failed setUpAll can stop test bodies without reaching the widget
      // tester's exception reporter.
      // ignore: invalid_use_of_visible_for_testing_member
      binding.results['Web test reporting'] = Failure(
        'Web test reporting',
        '${counts['notRun']} declared tests did not run.',
      );
    }
    (binding.reportData ??= {})[webTestSummaryKey] = {'version': 1, ...counts};
  });
}
