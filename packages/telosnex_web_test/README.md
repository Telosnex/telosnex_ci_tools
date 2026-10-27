# telosnex_web_test

Flutter web integration tests (`flutter drive -d web-server`) that keep
their logs and do not pass by mistake.

`integrationDriver()` alone has three gaps:

- **Silent runs.** flutter drive prints nothing of the browser console, and
  gets the results only when the run ends. A run that hangs, is stopped by a
  watchdog, or crashes the browser leaves almost nothing.
- **False passes.** "All tests passed." comes from
  `IntegrationTestWidgetsFlutterBinding.results`, which gets failures of
  `testWidgets` only. A plain `test()` that fails, a failing `setUp` or
  `tearDown`, or tests that never ran, pass.
- **Lost report data.** `integration_response_data.json` is written only when
  all tests passed.

## Use

In the app's `pubspec.yaml` (the example app, not the published package):

```yaml
dev_dependencies:
  telosnex_web_test:
    git:
      url: https://github.com/Telosnex/telosnex_ci_tools.git
      path: packages/telosnex_web_test
      ref: <tag>  # the same tag as your telosnex_ci_tools actions
```

In the test, first thing after the binding:

```dart
import 'package:telosnex_web_test/telosnex_web_test.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  installWebTestSupport(binding);
  // tests...
}
```

`test_driver/integration_test.dart`:

```dart
import 'package:telosnex_web_test/driver.dart';

Future<void> main() => webIntegrationDriver();
```

In CI, run flutter drive with `actions/web-driver` of this repository. It
gives the driver the log paths and uploads the logs; `require-result` checks
the response data:

```yaml
- uses: Telosnex/telosnex_ci_tools/actions/web-driver@<sha> # <tag>
  with:
    browser: chrome
    working-directory: example
    artifact-name: web-chrome-${{ matrix.compiler }}
    require-result: '.telosnexWebTestSummary.passed >= 12'
    run: |
      flutter drive --release -d web-server --browser-name chrome \
        --driver test_driver/integration_test.dart \
        --target integration_test/app_test.dart
```

## What it does

**In the app**, `installWebTestSupport`:

- Records every test's result (from `package:test_api`'s `LiveTest`, as
  Flutter's web runner does), adds the failures to `binding.results`, and
  fails the run when a declared test did not run. The counts go into
  `binding.reportData['telosnexWebTestSummary']`:
  `{version: 1, passed, failed, skipped, notRun}`.
- Keeps the page console: `console.debug/log/info/warn/error`, window errors
  and unhandled rejections, as `<ms> <level> <text>` lines (at most 20,000,
  2,000 characters each), and logs `==== test <name>` at the start of each
  test. `markWebTestStep('loading the model')` marks a step within one.
  `captureConsole: false` turns it off; off the web it does nothing.

**The driver**, `webIntegrationDriver`:

- Every 30 s (`pollInterval`) appends the new console lines to
  `web_console.log`, and prints a progress line when the page logged
  anything new. It reads the console once more at the end, also after a
  timeout. A line count that survives the page's drops means no line is
  written twice or skipped; dropped lines are noted in the log.
- Always writes `integration_response_data.json`.
- Prints each failure, the counts line
  (`TELOSNEX_WEB_TEST_SUMMARY: {...}`), and "All tests passed." or "Some
  tests failed.". It never prints the rest of the report data.
- Fails a run in which no test passed or failed (`requireTests`), and warns
  when the app did not call `installWebTestSupport`.

Paths: the `consoleLog` and `responseFile` arguments, else
`TELOSNEX_WEB_TEST_CONSOLE` and `TELOSNEX_WEB_TEST_RESPONSE` (web-driver sets
them), else `build/web_console.log` and
`build/integration_response_data.json`.

## Limits

- **Web Workers.** Their console is not captured: only the page's.
- **Polling.** A page that freezes loses the lines since the last poll (up to
  `pollInterval`). A page busy in a long synchronous call answers late; the
  poll gives up after 20 s and tries again.
- **Watchdogs.** Progress lines come only with new console lines, so a
  watchdog (`idle-minutes` of web-driver) still stops a page that hangs. A
  test that is slow and silent should call `markWebTestStep` now and then;
  `progressEveryPoll: true` prints every poll instead.
- **Privacy.** The console log has whatever the app logged. Uploads of
  `web-driver` are readable by anyone who can read the repository's
  Actions; set its `upload` to `failure` or `never`, or `captureConsole:
  false`, for apps that log secrets.

## Development

```sh
flutter pub get && (cd fixture && flutter pub get)
flutter analyze --fatal-infos
flutter test                                # VM tests
flutter test --platform chrome [--wasm]     # the console capture
```

`fixture/` is the app that `ci.yml` drives end to end with
`actions/web-driver`: a passing run that logs 6,000 lines, and a failing
plain `test()` that `integrationDriver()` would pass. Locally, with
chromedriver on port 4444:

```sh
cd fixture && flutter drive --release -d web-server --browser-name chrome \
  --driver test_driver/integration_test.dart \
  --target integration_test/fixture_test.dart \
  [--dart-define=FIXTURE_CASE=fail_plain] [--wasm]
```
