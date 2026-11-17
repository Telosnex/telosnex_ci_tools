@Timeout(Duration(minutes: 2))
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../actions/android-emulator/src/config.dart';
import '../actions/android-emulator/src/contract.dart';
import '../actions/android-emulator/src/diagnostics.dart';
import '../actions/android-emulator/src/lifecycle.dart';
import '../actions/android-emulator/src/supervisor.dart';
import 'support/fake_android.dart';

const _noGdb = Switches(gdb: false);

String _event(Map<String, Object?> event) => jsonEncode(event);

final _testStart = _event({
  'type': 'testStart',
  'test': {'id': 2, 'name': 'real test'},
});
final _loading = _event({
  'type': 'testStart',
  'test': {'id': 1, 'name': 'loading /x_test.dart'},
});
final _started = jsonEncode([
  {'event': 'test.startedProcess', 'params': {}},
]);

/// A bash command that the supervisor runs. [script] can use $ANDROID_*,
/// $SESSION (the session directory) and the helper `drop`, which writes an
/// adb disconnect of the selected serial to the adb server log.
List<String> _bash(String script) => [
  'bash',
  '-c',
  'drop() { echo "I adb : transport.cpp:1222 \$ANDROID_SERIAL: '
      'connection terminated: read failed" >> "\$SESSION/adb-server.log"; }\n'
      '$script',
];

void main() {
  late FakeAndroid fake;
  setUp(() => fake = FakeAndroid());
  tearDown(() => fake.dispose());

  Future<void> prepared({Switches switches = _noGdb}) =>
      prepare(fake.host(), fake.session, PrepareInputs(switches: switches));

  group('prepare', () {
    test(
      'installs the image, creates the AVD, and starts no emulator',
      () async {
        File('${fake.root.path}/image-failures').writeAsStringSync('1\n');
        await prepare(
          fake.host(),
          fake.session,
          const PrepareInputs(
            apiLevel: '36',
            switches: Switches(gdb: false, cores: 6, ramMb: null),
            emulatorArguments: ['-feature', '-Vulkan'],
          ),
        );
        final calls = fake.calls.readAsStringSync();
        // One failed install, then one that worked.
        expect(
          RegExp(
            r'^sdkmanager .*system-images',
            multiLine: true,
          ).allMatches(calls),
          hasLength(2),
        );
        expect(calls, isNot(contains('sudo')));
        final config = EmulatorConfig.read(fake.session);
        expect(config.extraArguments, ['-feature', '-Vulkan']);
        final ini = File(
          '${config.avdHome}/ci.avd/config.ini',
        ).readAsStringSync();
        expect(ini, contains('hw.cpu.ncore=6'));
        expect(ini, isNot(contains('hw.ramSize')));
        expect(ini, contains('hw.gpu.mode=swiftshader_indirect'));
        expect(
          File(fake.environment['GITHUB_ENV']!).readAsStringSync(),
          contains('ANDROID_AVD_HOME=${config.avdHome}'),
        );
        expect(await fake.aliveEmulators(), isEmpty);
        expect(Session.read(fake.session), isNull);
      },
    );

    test('a runner with no KVM fails', () async {
      await expectLater(
        prepare(
          fake.host({'TELOSNEX_ANDROID_TOOL_TEST_KVM': '/no/kvm'}),
          fake.session,
          const PrepareInputs(switches: _noGdb),
        ),
        throwsA(isA<LifecycleException>()),
      );
    });

    test('GDB is installed when it is missing', () async {
      await prepared(switches: const Switches());
      final calls = fake.calls.readAsStringSync();
      if (Process.runSync('which', ['gdb']).exitCode != 0) {
        expect(calls, contains('apt-get install'));
        expect(calls, contains('gdb'));
      }
    });
  });

  group('boot and stop', () {
    test(
      'boot writes session.json; adb-transport tcp uses port 5600',
      () async {
        await prepare(
          fake.host(),
          fake.session,
          const PrepareInputs(switches: Switches(gdb: false, tcp: true)),
        );
        final session = await boot(fake.host(), fake.session, tool: fake.tool);
        expect(session.consoleSerial, matches(RegExp(r'^emulator-\d+$')));
        expect(session.serial, '127.0.0.1:5600');
        expect(session.abi, 'x86_64');
        expect(Session.read(fake.session)!.serial, '127.0.0.1:5600');
        expect(fake.calls.readAsStringSync(), contains('-port'));
        await stop(fake.host(), fake.session);
        expect(await fake.aliveEmulators(), isEmpty);
      },
    );

    test('guest adbd that is not on tcp:5555 gets adb tcpip once', () async {
      await prepare(
        fake.host(),
        fake.session,
        const PrepareInputs(switches: Switches(gdb: false, tcp: true)),
      );
      File('${fake.root.path}/tcp-needs-tcpip').writeAsStringSync('');
      final session = await boot(fake.host(), fake.session, tool: fake.tool);
      expect(session.serial, '127.0.0.1:5600');
      expect(
        'tcpip 5555'.allMatches(fake.calls.readAsStringSync()),
        hasLength(1),
      );
      await stop(fake.host(), fake.session);
    });

    test('without TCP, the console serial', () async {
      await prepare(
        fake.host(),
        fake.session,
        const PrepareInputs(switches: Switches(gdb: false, tcp: true)),
      );
      File('${fake.root.path}/tcp-never').writeAsStringSync('');
      final session = await boot(fake.host(), fake.session, tool: fake.tool);
      expect(session.serial, session.consoleSerial);
      await stop(fake.host(), fake.session);
    });

    test('two boot --fresh in a row leave one emulator, and an emulator '
        'that the session did not start stays', () async {
      await prepared();
      final other = await Process.start(
        '${fake.root.path}/sdk/emulator/emulator',
        ['-avd', 'other'],
        environment: fake.environment,
      );
      addTearDown(other.kill);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(await fake.aliveEmulators(), hasLength(1));
      await boot(fake.host(), fake.session, tool: fake.tool, fresh: true);
      await boot(fake.host(), fake.session, tool: fake.tool, fresh: true);
      final alive = await fake.aliveEmulators();
      expect(alive, hasLength(2));
      expect(alive, contains(other.pid));
      await stop(fake.host(), fake.session);
      await stop(fake.host(), fake.session);
      expect(await fake.aliveEmulators(), [other.pid]);
      expect(fake.session.emulatorExit.existsSync(), isFalse);
    });

    test('boot without --fresh keeps a running session', () async {
      await prepared();
      await boot(fake.host(), fake.session, tool: fake.tool);
      final first = await fake.aliveEmulators();
      await boot(fake.host(), fake.session, tool: fake.tool);
      expect(await fake.aliveEmulators(), first);
      await stop(fake.host(), fake.session);
    });

    test('an emulator that stops by itself leaves the exit file', () async {
      await prepared();
      await boot(fake.host(), fake.session, tool: fake.tool);
      final [pid] = await fake.aliveEmulators();
      Process.killPid(pid, ProcessSignal.sigkill);
      for (var i = 0; i < 100 && !fake.session.emulatorExit.existsSync(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(readJson(fake.session.emulatorExit), {'exitCode': -9});
      await stop(fake.host(), fake.session);
    });
  });

  group('diagnostics', () {
    test('device state, and the guest log after a failure', () async {
      // A running device for the fake adb.
      File('${fake.root.path}/port-5554').writeAsStringSync('$pid\n');
      final output = Directory('${fake.root.path}/out');
      await deviceDiagnostics(
        fake.host(),
        'emulator-5554',
        output,
        'after_failure',
        afterFailure: true,
      );
      final text = File(
        '${output.path}/device-diagnostics.txt',
      ).readAsStringSync();
      expect(text, contains('===== after_failure'));
      expect(text, contains('--- dumpsys meminfo'));
      expect(
        File('${output.path}/logcat-dump.txt').readAsStringSync(),
        contains('dump line'),
      );
    });

    test('an offline device gets no device queries and no dump', () async {
      fake.state = 'offline';
      final output = Directory('${fake.root.path}/out');
      await deviceDiagnostics(
        fake.host(),
        '127.0.0.1:5600',
        output,
        'after_failure',
        afterFailure: true,
      );
      final text = File(
        '${output.path}/device-diagnostics.txt',
      ).readAsStringSync();
      expect(text, contains('127.0.0.1:5600 state: offline'));
      expect(text, isNot(contains('dumpsys')));
      expect(File('${output.path}/logcat-dump.txt').existsSync(), isFalse);
    });

    test('a serial that is not a device serial is not queried', () async {
      final output = Directory('${fake.root.path}/out');
      await deviceDiagnostics(fake.host(), 'x; rm', output, 'p');
      expect(
        File('${output.path}/device-diagnostics.txt').readAsStringSync(),
        isNot(contains('dumpsys')),
      );
    });

    test('logcat starts again from its last timestamp', () async {
      final log = File('${fake.root.path}/logcat.txt')
        ..writeAsStringSync('11-16 11:59:00.250  1  1 I old: line\n');
      expect(lastLogcatTime(log), '11-16 11:59:00.250');
      final stopped = Future<void>.delayed(const Duration(milliseconds: 500));
      await captureLogcat(fake.host(), 'emulator-5554', log, stopped);
      expect(fake.calls.readAsStringSync(), contains('-T 11-16 11:59:00.250'));
      expect(log.readAsStringSync(), contains('logcat line'));
      expect(lastLogcatTime(File('${fake.root.path}/none')), isNull);
    });
  });

  group('run', () {
    Future<(int, RunResult)> run(
      String script, {
      bool machine = true,
      Duration timeout = const Duration(seconds: 20),
      Map<String, String> extra = const {},
    }) async {
      await prepared();
      final host = fake.host({'SESSION': fake.session.path, ...extra});
      final code = await runSupervised(
        host,
        fake.session,
        fake.run,
        _bash(script),
        tool: fake.tool,
        flutterMachine: machine,
        timeout: timeout,
      );
      expect(await fake.aliveEmulators(), isEmpty, reason: 'run stops');
      return (code, RunResult.read(fake.run));
    }

    test('exit 0 passes with one attempt and its evidence', () async {
      final (code, result) = await run(
        'echo \'$_testStart\'; test "\$ANDROID_ATTEMPT" = 1; '
        'test "\$ANDROID_ABI" = x86_64; '
        'test -d "\$ANDROID_ATTEMPT_DIR"; test -n "\$ANDROID_SERIAL"',
      );
      expect(code, 0);
      expect(result.attempts, hasLength(1));
      final attempt = result.attempts.single;
      expect(attempt.markers, isEmpty);
      expect(attempt.testStarted, isTrue);
      expect(
        attempt.evidence,
        containsAll([
          'attempts/1/command.stdout',
          'attempts/1/emulator.log',
          'attempts/1/adb-server.log',
          'attempts/1/device-diagnostics.txt',
        ]),
      );
      expect(
        File('${fake.run.path}/attempts/1/command.stdout').readAsStringSync(),
        contains('real test'),
      );
      // The tool moved the evidence out of the session.
      expect(fake.session.adbServerLog.existsSync(), isFalse);
    });

    test('another exit code is returned unchanged', () async {
      final (code, result) = await run('exit 3');
      expect(code, 3);
      expect(result.attempts.single.exitCode, 3);
      expect(result.attempts.single.markers, isEmpty);
    });

    test('a disconnect before the first test retries once, and attempt 2 '
        'passes', () async {
      final (code, result) = await run(
        'echo \'$_loading\'; echo \'$_started\'\n'
        'if [ "\$ANDROID_ATTEMPT" = 1 ]; then drop; sleep 30; fi\n'
        'echo \'$_testStart\'',
      );
      expect(code, 0);
      expect(result.attempts.map((a) => a.exitCode), [kExitRetryable, 0]);
      expect(result.attempts.first.markers, [Marker.adbDisconnect.label]);
      expect(result.attempts.first.testStarted, isFalse);
      expect(
        result.attempts.first.evidence,
        contains('attempts/1/adb-server.log'),
      );
      expect(
        File('${fake.run.path}/attempts/1/adb-server.log').readAsStringSync(),
        contains('connection terminated'),
      );
      expect(
        File('${fake.run.path}/attempts/2/adb-server.log').readAsStringSync(),
        isNot(contains('connection terminated')),
      );
    });

    test(
      'a command that fails at once after a drop is still retried',
      () async {
        final (code, result) = await run(
          'if [ "\$ANDROID_ATTEMPT" = 1 ]; then drop; exit 1; fi',
        );
        expect(code, 0);
        expect(result.attempts, hasLength(2));
      },
    );

    test('a disconnect after the first test is not retried', () async {
      final (code, result) = await run('echo \'$_testStart\'; drop; sleep 30');
      expect(code, kExitInfrastructure);
      expect(result.attempts.single.markers, [Marker.adbDisconnect.label]);
      expect(result.attempts.single.testStarted, isTrue);
    });

    test('a disconnect of another serial is ignored', () async {
      final (code, _) = await run(
        'echo "I adb : 127.0.0.9:1: connection terminated" '
        '>> "\$SESSION/adb-server.log"; sleep 0.5; exit 0',
      );
      expect(code, 0);
    });

    test('a second early disconnect is not retried again', () async {
      final (code, result) = await run('drop; sleep 30');
      expect(code, kExitInfrastructure);
      expect(result.exitCode, kExitInfrastructure);
      expect(result.attempts.map((a) => a.exitCode), [
        kExitRetryable,
        kExitRetryable,
      ]);
    });

    test('a drop without --startup-protocol is not retried', () async {
      final (code, result) = await run('drop; sleep 30', machine: false);
      expect(code, kExitInfrastructure);
      expect(result.attempts, hasLength(1));
    });

    test('a long first attempt is not retried', () async {
      final (code, result) = await run(
        'sleep 0.6; drop; sleep 30',
        extra: {'TELOSNEX_ANDROID_TOOL_TEST_RETRY_WINDOW_MS': '500'},
      );
      expect(code, kExitInfrastructure);
      expect(result.attempts, hasLength(1));
    });

    test('an emulator exit is never retried', () async {
      final (code, result) = await run(
        'kill -9 \$(cat "\$FAKE"/emulators/* | head -1); sleep 30',
      );
      expect(code, kExitInfrastructure);
      expect(result.attempts.single.markers, [Marker.emulatorExit.label]);
      expect(result.attempts.single.emulatorStopped, isTrue);
      expect(
        result.attempts.single.evidence,
        contains('attempts/1/emulator-exit.json'),
      );
    });

    test('an emulator exit after a pass still fails', () async {
      final (code, result) = await run(
        'kill -9 \$(cat "\$FAKE"/emulators/* | head -1); sleep 0.5; exit 0',
      );
      expect(code, kExitInfrastructure);
      expect(result.attempts.single.markers, [Marker.emulatorExit.label]);
    });

    test('three offline probes stop the command', () async {
      final (code, result) = await run(
        'echo offline > "\$FAKE/state"; sleep 30',
      );
      expect(code, kExitInfrastructure);
      expect(result.attempts.single.markers, [Marker.deviceOffline.label]);
    });

    test('no test in the startup window stops the command', () async {
      final (code, result) = await run(
        'echo \'$_started\'; sleep 30',
        extra: {'TELOSNEX_ANDROID_TOOL_TEST_STARTUP_MS': '300'},
      );
      expect(code, kExitInfrastructure);
      expect(result.attempts.single.markers, [Marker.startupTimeout.label]);
    });

    test('a command that exits 75 by itself is not retried', () async {
      final (code, result) = await run('exit 75');
      expect(code, kExitInfrastructure);
      expect(result.attempts, hasLength(1));
    });

    test('an attempt that takes too long exits 124', () async {
      final (code, _) = await run(
        'sleep 30',
        timeout: const Duration(seconds: 1),
      );
      expect(code, kExitTimeout);
    });

    test('result.json has no command line and no output', () async {
      await run(
        'echo SECRET_OUTPUT; echo SECRET_ERROR >&2; exit 4 # SECRET_ARG',
      );
      final text = RunResult.file(fake.run).readAsStringSync();
      expect(text, isNot(contains('SECRET')));
    });
  });

  group('command line', () {
    Future<ProcessResult> cli(List<String> arguments) => Process.run(
      Platform.resolvedExecutable,
      [fake.tool, ...arguments],
      environment: {
        ...fake.environment,
        'GITHUB_OUTPUT': '${fake.root.path}/github-output',
      },
      includeParentEnvironment: false,
    );

    test(
      'prepare and boot as the action calls them, then run and stop',
      () async {
        final session = fake.session.path;
        final prepared = await cli([
          'prepare', '--session', session, '--api-level', '36', //
          '--target', 'google_apis', '--device', 'pixel_6', '--ram-mb', '4096',
          '--cores', '', '--gpu', 'swiftshader_indirect',
          '--emulator-args', '-feature -Vulkan', '--boot-timeout-minutes', '15',
          '--gdb', 'false', '--adb-trace', '', '--adb-transport', 'emulator',
        ]);
        expect(prepared.exitCode, 0, reason: '${prepared.stderr}');
        final booted = await cli(['boot', '--session', session]);
        expect(booted.exitCode, 0, reason: '${booted.stderr}');
        expect(
          File('${fake.root.path}/github-output').readAsStringSync(),
          matches(RegExp(r'^serial=emulator-\d+\n$')),
        );
        final ran = await cli([
          'run', '--session', session, '--run-dir', fake.run.path, //
          '--startup-protocol', 'flutter-machine', '--', 'bash', '-c', 'exit 5',
        ]);
        expect(ran.exitCode, 5, reason: '${ran.stderr}');
        expect(RunResult.read(fake.run).exitCode, 5);
        expect((await cli(['stop', '--session', session])).exitCode, 0);
        expect(await fake.aliveEmulators(), isEmpty);
      },
    );

    test('bad arguments exit 2', () async {
      for (final arguments in [
        <String>[],
        ['boot'],
        ['nope', '--session', fake.session.path],
        ['run', '--session', fake.session.path, '--run-dir', fake.run.path],
        ['prepare', '--session', fake.session.path, '--cores', '99'],
        ['boot', '--session', fake.session.path, '--bad'],
      ]) {
        expect(
          (await cli(arguments)).exitCode,
          kExitConfig,
          reason: '$arguments',
        );
      }
    });

    test('boot before prepare is an error', () async {
      expect(
        (await cli(['boot', '--session', fake.session.path])).exitCode,
        kExitConfig,
      );
    });
  });

  group('I7', () {
    Outcome outcome({
      Duration elapsed = const Duration(seconds: 100),
      bool retryable = true,
      bool testStarted = false,
      bool emulatorStopped = false,
    }) => Outcome(
      exitCode: retryable ? kExitRetryable : kExitInfrastructure,
      elapsed: elapsed,
      markers: [Marker.adbDisconnect],
      testStarted: testStarted,
      emulatorStopped: emulatorStopped,
      retryable: retryable,
    );

    bool retry(Outcome o, {int attempt = 1, bool machine = true}) =>
        shouldRetry(
          o,
          attempt: attempt,
          window: kRetryWindow,
          flutterMachine: machine,
        );

    test('the truth table', () {
      expect(retry(outcome()), isTrue);
      expect(retry(outcome(elapsed: const Duration(seconds: 899))), isTrue);
      expect(retry(outcome(elapsed: const Duration(seconds: 900))), isFalse);
      expect(retry(outcome(retryable: false)), isFalse);
      expect(retry(outcome(testStarted: true)), isFalse);
      expect(retry(outcome(emulatorStopped: true)), isFalse);
      expect(retry(outcome(), attempt: 2), isFalse);
      expect(retry(outcome(), machine: false), isFalse);
    });
  });
}
