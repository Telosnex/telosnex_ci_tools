// Runs the integration test APKs of actions/android-test-apks on the adb
// device ANDROID_SERIAL, one at a time: install, launch, and wait for the
// result line that flutter_test's reporter logs when a test file runs as the
// app itself ("All tests passed!", "Some tests failed.", "All tests
// skipped.").
//
// usage: dart run_tests.dart <apk directory> <idle minutes> <minutes per file>
//
// The directory has apks.tsv: one line per APK, "<file>\t<package>\t
// <activity>\t<test file>". The flutter lines of each run go to stdout.
// Exits 1 if any test file fails, crashes, stalls or gives no result.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  if (args.length != 3) {
    stderr.writeln(
      'usage: dart run_tests.dart <apk directory> <idle minutes> '
      '<minutes per file>',
    );
    exit(64);
  }
  final dir = args[0];
  final idle = Duration(minutes: int.parse(args[1]));
  final limit = Duration(minutes: int.parse(args[2]));
  final manifest = File('$dir/apks.tsv');
  if (!manifest.existsSync()) {
    stderr.writeln(
      '$dir has no apks.tsv: download the android-test-apks artifact.',
    );
    exit(1);
  }
  final summary = <String>[];
  var failed = 0;
  for (final line in manifest.readAsLinesSync()) {
    if (line.trim().isEmpty) continue;
    final [file, package, activity, target] = line.split('\t');
    stdout.writeln('::group::$target');
    final result = await runOne(
      apk: '$dir/$file',
      package: package,
      activity: activity,
      idle: idle,
      limit: limit,
    );
    stdout.writeln('::endgroup::');
    final ok =
        result.outcome == Outcome.passed || result.outcome == Outcome.skipped;
    if (!ok) {
      failed++;
      stdout.writeln('::error::$target: ${result.message}');
      for (final l in result.tail) {
        stdout.writeln('  $l');
      }
    } else if (result.outcome == Outcome.skipped) {
      stdout.writeln('::warning::$target: every test was skipped.');
    }
    summary.add('| `$target` | ${result.message} |');
    stdout.writeln('$target: ${result.message}');
  }
  final summaryFile = Platform.environment['GITHUB_STEP_SUMMARY'];
  if (summaryFile != null && summary.isNotEmpty) {
    File(summaryFile).writeAsStringSync(
      '| Test file | Result |\n|---|---|\n${summary.join('\n')}\n',
      mode: FileMode.append,
    );
  }
  if (summary.isEmpty) {
    stdout.writeln('::error::apks.tsv lists no APKs.');
    exit(1);
  }
  if (failed > 0) exit(1);
}

enum Outcome { passed, skipped, failed, crashed, stalled, timedOut }

final class RunResult {
  RunResult(this.outcome, this.message, [this.tail = const []]);

  final Outcome outcome;
  final String message;

  /// The last log lines, for a run that ended without a result.
  final List<String> tail;
}

/// What a flutter_test reporter line says, or null if it ends no run.
Outcome? resultOf(String message) {
  if (message.endsWith('All tests passed!')) return Outcome.passed;
  if (message.endsWith('All tests skipped.')) return Outcome.skipped;
  if (message.endsWith('Some tests failed.')) return Outcome.failed;
  return null;
}

/// The progress counts of a reporter line ("00:12 +3 ~1 -2: name"), or null.
({int passed, int skipped, int failed})? countsOf(String message) {
  final m = RegExp(
    r'^\d+:\d+ \+(\d+)(?: ~(\d+))?(?: -(\d+))?:',
  ).firstMatch(message);
  if (m == null) return null;
  return (
    passed: int.parse(m[1]!),
    skipped: int.parse(m[2] ?? '0'),
    failed: int.parse(m[3] ?? '0'),
  );
}

/// The tag and message of a `logcat -v tag` line ("I/flutter ( 123): text"
/// or "I/flutter: text"), or null.
(String, String)? parseLogcat(String line) {
  final m = RegExp(
    r'^[VDIWEF]/([^(:]*?)\s*(?:\(\s*\d+\))?: ?(.*)$',
  ).firstMatch(line);
  if (m == null) return null;
  return (m[1]!, m[2]!);
}

Future<ProcessResult> adb(List<String> args) => Process.run('adb', args);

Future<RunResult> runOne({
  required String apk,
  required String package,
  required String activity,
  required Duration idle,
  required Duration limit,
}) async {
  // A previous run's app could still hold the device.
  await adb(['uninstall', package]);
  final install = await adb(['install', '-r', '-t', '-g', apk]);
  if (install.exitCode != 0) {
    return RunResult(Outcome.failed, 'adb install failed', [
      ...LineSplitter.split('${install.stdout}${install.stderr}'),
    ]);
  }
  await adb(['logcat', '-c']);
  final logcat = await Process.start('adb', [
    'logcat',
    '-v',
    'tag',
    '-b',
    'main,crash',
  ]);
  final tail = <String>[];
  final done = Completer<RunResult>();
  var lastLine = DateTime.now();
  ({int passed, int skipped, int failed}) counts = (
    passed: 0,
    skipped: 0,
    failed: 0,
  );
  String counted() =>
      '${counts.passed} passed, ${counts.failed} failed'
      '${counts.skipped > 0 ? ', ${counts.skipped} skipped' : ''}';
  final sub = logcat.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((line) {
        final parsed = parseLogcat(line);
        if (parsed == null) return;
        final (tag, message) = parsed;
        final crash =
            tag == 'AndroidRuntime' || tag == 'DEBUG' || tag == 'libc';
        if (tag != 'flutter' && !crash) return;
        tail.add(line);
        if (tail.length > 60) tail.removeAt(0);
        if (tag == 'flutter') {
          stdout.writeln(message);
          lastLine = DateTime.now();
          counts = countsOf(message) ?? counts;
          final outcome = resultOf(message);
          if (outcome != null && !done.isCompleted) {
            done.complete(RunResult(outcome, counted()));
          }
        } else {
          stdout.writeln(line);
        }
      });
  final started = DateTime.now();
  final start = await adb([
    'shell',
    'am',
    'start',
    '-W',
    '-n',
    '$package/$activity',
  ]);
  if (start.exitCode != 0 || '${start.stdout}'.contains('Error')) {
    if (!done.isCompleted) {
      done.complete(
        RunResult(Outcome.failed, 'am start failed', [
          ...LineSplitter.split('${start.stdout}${start.stderr}'),
        ]),
      );
    }
  }
  // The app process: gone before a result line is a crash.
  final watch = Timer.periodic(const Duration(seconds: 3), (_) async {
    if (done.isCompleted) return;
    final now = DateTime.now();
    if (now.difference(started) > limit) {
      done.complete(
        RunResult(
          Outcome.timedOut,
          'no result after ${limit.inMinutes} minutes (${counted()})',
          tail,
        ),
      );
      return;
    }
    if (now.difference(lastLine) > idle) {
      done.complete(
        RunResult(
          Outcome.stalled,
          'no output for ${idle.inMinutes} minutes (${counted()})',
          tail,
        ),
      );
      return;
    }
    final pid = await adb(['shell', 'pidof', package]);
    if ('${pid.stdout}'.trim().isEmpty && !done.isCompleted) {
      // The result line can still be on its way through logcat.
      await Future<void>.delayed(const Duration(seconds: 3));
      if (!done.isCompleted) {
        done.complete(
          RunResult(
            Outcome.crashed,
            'the app ended without a result (${counted()})',
            tail,
          ),
        );
      }
    }
  });
  final result = await done.future;
  watch.cancel();
  // The lines right after the result: exceptions are logged before it, and
  // the reporter's own errors after.
  await Future<void>.delayed(const Duration(seconds: 1));
  await sub.cancel();
  logcat.kill();
  await adb(['shell', 'am', 'force-stop', package]);
  await adb(['uninstall', package]);
  return result;
}
