// `run`: boot, run a command under supervision, retry per I7, stop.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'config.dart';
import 'contract.dart';
import 'diagnostics.dart';
import 'emulator.dart';
import 'host.dart';
import 'lifecycle.dart';
import 'process_tree.dart';

void _say(String line) => stderr.writeln(line);

/// The result of one supervised command.
final class Outcome {
  Outcome({
    required this.exitCode,
    required this.elapsed,
    required this.markers,
    required this.testStarted,
    required this.emulatorStopped,
    this.retryable = false,
  });

  /// The exit code of the attempt. [kExitRetryable] when [retryable].
  final int exitCode;
  final Duration elapsed;
  final List<Marker> markers;
  final bool testStarted;
  final bool emulatorStopped;

  /// adb lost the device before the first test, and nothing else failed.
  final bool retryable;
}

/// Watches flutter test --machine output for the first real test.
final class StartupWatch {
  StartupWatch(this.timeout, this.onTimeout);

  final Duration timeout;
  final void Function() onTimeout;
  Timer? _timer;
  var _started = false;

  bool get testStarted => _started;

  void add(String line) {
    if (_started) return;
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      return;
    }
    for (final event in decoded is List ? decoded : [decoded]) {
      if (event is! Map) continue;
      final test = event['test'];
      if (event['type'] == 'testStart' &&
          test is Map &&
          test['name'] is String &&
          !(test['name'] as String).startsWith('loading ')) {
        _started = true;
        _timer?.cancel();
        return;
      }
      // A repeated notification must not move the deadline.
      if (event['event'] == 'test.startedProcess') {
        _timer ??= Timer(timeout, onTimeout);
      }
    }
  }

  void dispose() => _timer?.cancel();
}

/// Reads what the adb server appends to its log from [offset] on.
final class AdbLogWatch {
  AdbLogWatch(this.log, this.serial)
    : _offset = log.existsSync() ? log.lengthSync() : 0;

  final File log;
  final String serial;
  int _offset;
  var _partial = '';
  var _seen = false;

  /// Whether the log shows that [serial] was lost since the start.
  Future<bool> disconnected() async {
    if (_seen) return true;
    if (!log.existsSync()) return false;
    final length = await log.length();
    if (length <= _offset) return false;
    final file = await log.open();
    final List<int> bytes;
    try {
      await file.setPosition(_offset);
      bytes = await file.read(length - _offset);
    } finally {
      await file.close();
    }
    _offset = length;
    final lines = '$_partial${utf8.decode(bytes, allowMalformed: true)}'.split(
      '\n',
    );
    _partial = lines.removeLast();
    return _seen = lines.any((line) => isAdbDisconnect(line, serial: serial));
  }
}

/// Runs [command] once on the booted device of [session]. Its stdout and
/// stderr go to files in [attemptDirectory].
Future<Outcome> superviseAttempt(
  Host host,
  Directory session,
  Session device,
  Directory attemptDirectory,
  List<String> command, {
  required int attempt,
  required bool flutterMachine,
  required Duration timeout,
}) async {
  attemptDirectory.createSync(recursive: true);
  final started = DateTime.now();
  await deviceDiagnostics(host, device.serial, session, 'before_test');
  final adbLog = AdbLogWatch(session.adbServerLog, device.serial);
  final Process process;
  try {
    process = await Process.start(
      command.first,
      command.skip(1).toList(),
      environment: {
        ...host.environment,
        'ANDROID_SERIAL': device.serial,
        'ANDROID_CONSOLE_SERIAL': device.consoleSerial,
        'ANDROID_ABI': device.abi,
        'ANDROID_ATTEMPT': '$attempt',
        'ANDROID_ATTEMPT_DIR': attemptDirectory.absolute.path,
      },
      includeParentEnvironment: false,
    );
  } on ProcessException {
    _say('The command could not start.');
    return Outcome(
      exitCode: kExitConfig,
      elapsed: DateTime.now().difference(started),
      markers: const [],
      testStarted: false,
      emulatorStopped: false,
    );
  }
  final out = File('${attemptDirectory.path}/command.stdout').openWrite();
  final err = File('${attemptDirectory.path}/command.stderr').openWrite();
  final stdoutStream = process.stdout.asBroadcastStream();
  final outDone = stdoutStream.listen(out.add).asFuture<void>();
  final errDone = process.stderr.listen(err.add).asFuture<void>();
  final markers = <Marker>[];
  final lost = Completer<void>();
  var retryable = false;
  var stopped = false;
  void lose(Marker marker, String text) {
    if (stopped || lost.isCompleted) return;
    markers.add(marker);
    _say(marker.line(text));
    lost.complete();
  }

  final startup = StartupWatch(
    host.startupTimeout,
    () => lose(
      Marker.startupTimeout,
      'the VM service started, but no test started',
    ),
  );
  final lines = flutterMachine
      ? stdoutStream
            .transform(const Utf8Decoder(allowMalformed: true))
            .transform(const LineSplitter())
            .listen(startup.add)
      : null;
  var checking = false;
  var offline = 0;
  Future<void> check() async {
    if (checking || stopped || lost.isCompleted) return;
    checking = true;
    try {
      if (await adbLog.disconnected()) {
        retryable = !startup.testStarted;
        lose(Marker.adbDisconnect, 'the adb server lost the device');
        return;
      }
      if (session.emulatorExit.existsSync()) {
        lose(Marker.emulatorExit, 'the emulator stopped');
        return;
      }
      final state = (await host.device(device.serial, [
        'get-state',
      ], timeout: const Duration(seconds: 5))).line;
      offline = state == 'device' ? 0 : offline + 1;
      if (offline >= 3) {
        lose(Marker.deviceOffline, 'the device is $state');
      }
    } on Object {
      // A failed probe is not a test failure.
    } finally {
      checking = false;
    }
  }

  final timer = Timer.periodic(host.healthInterval, (_) => unawaited(check()));
  var code = 0;
  var timedOut = false;
  try {
    await Future.any<Object?>([
      process.exitCode,
      lost.future,
    ]).timeout(timeout, onTimeout: () => timedOut = true);
    timer.cancel();
    if (lost.isCompleted || timedOut) {
      if (!session.emulatorExit.existsSync()) {
        await deviceDiagnostics(
          host,
          device.serial,
          session,
          'before_stop',
          afterFailure: true,
        );
      }
      await _stopCommand(host, process);
      code = timedOut && !lost.isCompleted ? kExitTimeout : kExitInfrastructure;
    } else {
      code = await process.exitCode;
      // A command that exits at once must not skip the last check.
      while (checking) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      if (session.emulatorExit.existsSync()) {
        lose(Marker.emulatorExit, 'the emulator stopped');
        code = kExitInfrastructure;
      } else if (code != 0 && await adbLog.disconnected()) {
        retryable = !startup.testStarted;
        lose(Marker.adbDisconnect, 'the adb server lost the device');
        code = kExitInfrastructure;
      } else if (code == kExitRetryable) {
        // Only the watcher makes an attempt retryable.
        code = kExitInfrastructure;
      }
      if (code != 0) {
        await deviceDiagnostics(
          host,
          device.serial,
          session,
          'after_failure',
          afterFailure: !session.emulatorExit.existsSync(),
        );
      }
    }
    await Future.wait([
      outDone,
      errDone,
    ]).timeout(host.terminationGrace, onTimeout: () => []);
  } finally {
    stopped = true;
    timer.cancel();
    startup.dispose();
    await lines?.cancel();
    await out.close();
    await err.close();
  }
  // When QEMU stops, adb loses the device before GDB has printed the
  // backtrace and the daemon has written the exit file.
  if (markers.contains(Marker.adbDisconnect) &&
      !markers.contains(Marker.emulatorExit)) {
    final until = DateTime.now().add(host.exitWait);
    while (!session.emulatorExit.existsSync() &&
        DateTime.now().isBefore(until)) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }
  final emulatorStopped = session.emulatorExit.existsSync();
  if (emulatorStopped && !markers.contains(Marker.emulatorExit)) {
    markers.add(Marker.emulatorExit);
    _say(Marker.emulatorExit.line('the emulator stopped'));
    if (code == 0) code = kExitInfrastructure;
  }
  retryable &= !emulatorStopped && markers.length == 1;
  return Outcome(
    exitCode: retryable ? kExitRetryable : code,
    elapsed: DateTime.now().difference(started),
    markers: markers,
    testStarted: startup.testStarted,
    emulatorStopped: emulatorStopped,
    retryable: retryable,
  );
}

Future<void> _stopCommand(Host host, Process process) async {
  await stopProcessTree(process.pid, ProcessSignal.sigterm);
  final exited = await process.exitCode
      .then((_) => true)
      .timeout(host.terminationGrace, onTimeout: () => false);
  if (!exited) {
    await stopProcessTree(process.pid, ProcessSignal.sigkill);
    await process.exitCode.timeout(host.terminationGrace, onTimeout: () => -1);
  }
}

/// I7: retry only after attempt 1 lost adb before its first test, with the
/// emulator still running, in less than the retry window.
bool shouldRetry(
  Outcome outcome, {
  required int attempt,
  required Duration window,
  required bool flutterMachine,
}) =>
    flutterMachine &&
    attempt == 1 &&
    outcome.retryable &&
    !outcome.testStarted &&
    !outcome.emulatorStopped &&
    outcome.elapsed < window;

/// Moves the evidence of the session into [attemptDirectory], and writes the
/// filtered backtrace. Returns the evidence paths relative to [run].
List<String> collectEvidence(
  Directory session,
  Directory attemptDirectory,
  Directory run,
) {
  attemptDirectory.createSync(recursive: true);
  for (final name in kEvidenceFiles) {
    final source = File('${session.path}/$name');
    if (source.existsSync()) {
      source.renameSync('${attemptDirectory.path}/$name');
    }
  }
  final log = File('${attemptDirectory.path}/emulator.log');
  if (log.existsSync()) {
    final frames = summarizeBacktrace(
      const LineSplitter().convert(
        utf8.decode(log.readAsBytesSync(), allowMalformed: true),
      ),
    );
    if (frames.isNotEmpty) {
      File('${attemptDirectory.path}/backtrace.txt').writeAsStringSync(frames);
    }
  }
  final prefix = run.absolute.path.length + 1;
  return [
    for (final file in attemptDirectory.listSync().whereType<File>())
      file.absolute.path.substring(prefix),
  ]..sort();
}

/// Boots, runs [command] with supervision and at most one retry (I7), and
/// stops. Writes RUN_DIR/result.json. Never returns [kExitRetryable].
Future<int> runSupervised(
  Host host,
  Directory session,
  Directory run,
  List<String> command, {
  required String tool,
  bool flutterMachine = false,
  Duration timeout = const Duration(minutes: 70),
}) async {
  final started = DateTime.now();
  RunResult.file(run).parent.createSync(recursive: true);
  if (RunResult.file(run).existsSync()) RunResult.file(run).deleteSync();
  final attemptsDirectory = Directory('${run.path}/attempts');
  if (attemptsDirectory.existsSync()) {
    attemptsDirectory.deleteSync(recursive: true);
  }
  final attempts = <AttemptResult>[];
  var code = kExitInfrastructure;
  try {
    for (var attempt = 1; attempt <= 2; attempt++) {
      final directory = Directory('${attemptsDirectory.path}/$attempt');
      final bootStarted = DateTime.now();
      Outcome outcome;
      try {
        final device = await boot(
          host,
          session,
          tool: tool,
          fresh: attempt > 1,
        );
        outcome = await superviseAttempt(
          host,
          session,
          device,
          directory,
          command,
          attempt: attempt,
          flutterMachine: flutterMachine,
          timeout: timeout,
        );
      } on LifecycleException catch (error) {
        _say('Boot failed: $error');
        final exited = session.emulatorExit.existsSync();
        outcome = Outcome(
          exitCode: kExitInfrastructure,
          elapsed: DateTime.now().difference(bootStarted),
          markers: [if (exited) Marker.emulatorExit],
          testStarted: false,
          emulatorStopped: exited,
        );
      }
      await stop(host, session);
      attempts.add(
        AttemptResult(
          attempt: attempt,
          exitCode: outcome.exitCode,
          elapsed: outcome.elapsed,
          markers: [for (final marker in outcome.markers) marker.label],
          testStarted: outcome.testStarted,
          emulatorStopped: outcome.emulatorStopped,
          evidence: collectEvidence(session, directory, run),
        ),
      );
      code = outcome.exitCode;
      if (!shouldRetry(
        outcome,
        attempt: attempt,
        window: host.retryWindow,
        flutterMachine: flutterMachine,
      )) {
        break;
      }
      _say(
        'adb lost the device before the first test. '
        'Retrying once on a new emulator.',
      );
    }
  } finally {
    if (code == kExitRetryable) code = kExitInfrastructure;
    RunResult(
      exitCode: code,
      elapsed: DateTime.now().difference(started),
      attempts: attempts,
    ).write(run);
  }
  stdout.writeln(
    'Android run: exit $code after ${attempts.length} '
    'attempt${attempts.length == 1 ? '' : 's'}.',
  );
  return code;
}
