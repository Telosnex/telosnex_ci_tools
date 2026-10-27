// The end-to-end test of telosnex_web_test (ci.yml):
//
// flutter drive -d web-server --browser-name chrome --release \
//   --driver test_driver/integration_test.dart \
//   --target integration_test/fixture_test.dart [--wasm] \
//   [--dart-define=FIXTURE_CASE=fail_plain]
//
// pass (the default) passes, logs more console lines than one poll reads,
// and runs longer than one poll interval. fail_plain has a plain test() that
// fails: integrationDriver() would report "All tests passed".
import 'dart:js_interop';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:telosnex_web_test/telosnex_web_test.dart';
import 'package:telosnex_web_test_fixture/main.dart';

const _case = String.fromEnvironment('FIXTURE_CASE', defaultValue: 'pass');

@JS('console.log')
external void _log(String message);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  installWebTestSupport(binding);

  tearDownAll(() {
    binding.reportData = {...?binding.reportData, 'fixture': _case};
  });

  testWidgets('pumps the app', (tester) async {
    await tester.pumpWidget(const FixtureApp());
    expect(find.text('fixture'), findsOneWidget);
    _log('fixture: pumped');
  });

  if (_case == 'fail_plain') {
    test('plain test fails', () => fail('the expected failure'));
    return;
  }

  test('logs more lines than one poll reads', () async {
    for (var i = 0; i < 6000; i++) {
      _log('fixture: line $i');
    }
    // Longer than the driver's 2 s poll interval: progress lines.
    await Future<void>.delayed(const Duration(seconds: 5));
    markWebTestStep('after the wait');
    print('fixture: last line');
  });

  test('plain test passes', () {});
}
