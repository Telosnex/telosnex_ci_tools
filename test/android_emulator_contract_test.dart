import 'dart:io';

import 'package:test/test.dart';

import '../actions/android-emulator/src/contract.dart';
import '../actions/android-emulator/src/emulator.dart';

const _frames = '''
Starting program: /private/emulator --token=SECRET_ARGV
Thread 4 "SECRET_THREAD" received signal SIGSEGV, Segmentation fault.
#0  0xabcdef in gfxstream::RenderThread::main (password=SECRET_ARGUMENT) from /private/libgfxstream.so
        password = SECRET_LOCAL
Thread 2 (Thread 0xdef (LWP 789) "SECRET_THREAD_NAME"):
#0  0x123abc in ?? () from /private/libvulkan.so
#1  0x234abc in unsafe<"SECRET_TEMPLATE"> () from /private/libbad.so
warning: SECRET_WARNING
172     fatal("SECRET_SOURCE");
''';

void main() {
  const fixtures = 'test/fixtures/android_emulator';

  test('the session.json fixture parses and writes back the same', () {
    final directory = Directory(fixtures);
    final session = Session.read(directory)!;
    expect(session.consoleSerial, 'emulator-5554');
    expect(session.serial, '127.0.0.1:5600');
    expect(session.abi, 'x86_64');
    expect(session.toJson(), readJson(Session.file(directory)));
  });

  test('the result.json fixture parses and writes back the same', () {
    final directory = Directory(fixtures);
    final result = RunResult.read(directory);
    expect(result.exitCode, 0);
    expect(result.attempts.map((a) => a.exitCode), [75, 0]);
    expect(result.attempts.first.markers, [Marker.adbDisconnect.label]);
    expect(result.attempts.first.testStarted, isFalse);
    expect(result.toJson(), readJson(RunResult.file(directory)));
  });

  test('an unknown schema version is an error', () {
    expect(() => Session.fromJson({'schemaVersion': 2}), throwsFormatException);
  });

  test('markers have the prefixes of the contract', () {
    expect(Marker.values.map((m) => m.prefix), [
      'ANDROID_ADB_DISCONNECT',
      'ANDROID_EMULATOR_EXIT',
      'ANDROID_DEVICE_OFFLINE',
      'ANDROID_TEST_STARTUP_TIMEOUT',
    ]);
    expect(Marker.adbDisconnect.line('lost'), 'ANDROID_ADB_DISCONNECT: lost');
    expect([kExitConfig, kExitTimeout, kExitInfrastructure], [2, 124, 125]);
  });

  group('switches', () {
    test('defaults', () {
      final switches = Switches.resolve({}, {});
      expect(switches.gdb, isTrue);
      expect(switches.adbTrace, isFalse);
      expect(switches.cores, 4);
      expect(switches.tcp, isFalse);
      expect(switches.ramMb, 4096);
    });

    test('an input wins, then the variable', () {
      const environment = {
        'TELOSNEX_ANDROID_GDB': 'false',
        'TELOSNEX_ANDROID_ADB_TRACE': 'true',
        'TELOSNEX_ANDROID_EMULATOR_CORES': '6',
      };
      final fromEnvironment = Switches.resolve({'gdb': ''}, environment);
      expect(fromEnvironment.gdb, isFalse);
      expect(fromEnvironment.adbTrace, isTrue);
      expect(fromEnvironment.cores, 6);
      final fromInputs = Switches.resolve({
        'gdb': 'true',
        'adb-trace': 'false',
        'cores': 'default',
        'adb-transport': 'tcp',
        'ram-mb': 'default',
      }, environment);
      expect(fromInputs.gdb, isTrue);
      expect(fromInputs.adbTrace, isFalse);
      expect(fromInputs.cores, isNull);
      expect(fromInputs.tcp, isTrue);
      expect(fromInputs.ramMb, isNull);
    });

    test('only false turns GDB off; only true turns the trace on', () {
      expect(Switches.resolve({'gdb': 'no'}, {}).gdb, isTrue);
      expect(Switches.resolve({'adb-trace': 'yes'}, {}).adbTrace, isFalse);
    });

    test('bad values are errors', () {
      for (final bad in ['0', '17', '6; rm -rf /', 'x']) {
        expect(
          () => Switches.resolve({'cores': bad}, {}),
          throwsFormatException,
        );
      }
      expect(
        () => Switches.resolve({'adb-transport': 'usb'}, {}),
        throwsFormatException,
      );
      expect(
        () => Switches.resolve({'ram-mb': '1'}, {}),
        throwsFormatException,
      );
    });

    test('they survive JSON', () {
      final switches = Switches.resolve({'cores': 'default'}, {});
      expect(Switches.fromJson(switches.toJson()).toJson(), switches.toJson());
    });
  });

  group('emulator command', () {
    test('GDB captures frames without values and never dumps cores', () {
      final command = emulatorCommand(
        '/sdk',
        'ci',
        gpu: 'swiftshader_indirect',
      );
      expect(command.take(3), ['gdb', '--batch', '--return-child-result']);
      expect(
        command,
        containsAll([
          'set auto-load off',
          'set print frame-arguments none',
          'set print entry-values no',
          'set disable-randomization off',
          'handle SIGPIPE nostop noprint pass',
          'handle SIGUSR1 SIGUSR2 SIGALRM nostop noprint pass',
          'thread apply all bt 20',
          '/sdk/emulator/emulator',
          '-no-window',
          '-no-snapshot',
          '-accel',
          'on',
        ]),
      );
      expect(
        command.join(' '),
        isNot(anyOf(contains('bt full'), contains('generate-core'))),
      );
    });

    test('without GDB, the same emulator arguments', () {
      final traced = emulatorCommand('/sdk', 'ci', gpu: 'host');
      final direct = emulatorCommand(
        '/sdk',
        'ci',
        gpu: 'host',
        debugger: false,
      );
      expect(direct.first, '/sdk/emulator/emulator');
      expect(direct, isNot(contains('--args')));
      expect(
        direct.skip(1),
        traced.skip(traced.indexOf('/sdk/emulator/emulator') + 1),
      );
    });

    test('the adb trace and extra arguments come last', () {
      final command = emulatorCommand(
        '/sdk',
        'ci',
        gpu: 'host',
        adbTrace: true,
        extra: splitArguments(' -feature  -Vulkan '),
      );
      expect(command.sublist(command.length - 4), [
        '-debug',
        'adb,adbserver,adbclient',
        '-feature',
        '-Vulkan',
      ]);
      expect(splitArguments('  '), isEmpty);
      expect(
        emulatorCommand('/sdk', 'ci', gpu: 'host'),
        isNot(contains('-debug')),
      );
    });
  });

  test('the backtrace has the signal and symbols, not runtime data', () {
    final text = summarizeBacktrace(_frames.split('\n'));
    expect(text, contains('Signal: SIGSEGV'));
    expect(
      text,
      contains('gfxstream::RenderThread::main from libgfxstream.so'),
    );
    expect(text, contains('Thread 2:'));
    expect(text, contains('?? from libvulkan.so'));
    expect(
      text,
      isNot(anyOf(contains('SECRET'), contains('/private'), contains('LWP'))),
    );
    expect(
      summarizeBacktrace(['Program terminated with signal SIGABRT, Aborted.']),
      'Signal: SIGABRT\n',
    );
  });

  test('serials and disconnect lines', () {
    const emulatorDrop =
        'I adb : transport.cpp:1222 emulator-5554: connection terminated: read failed';
    const tcpDrop =
        'I adb : transport.cpp:1222 127.0.0.1:5600: connection terminated: write failed';
    expect(isDeviceSerial('emulator-5554'), isTrue);
    expect(isDeviceSerial('127.0.0.1:5600'), isTrue);
    expect(isDeviceSerial('10.0.0.2:5555'), isFalse);
    expect(isDeviceSerial('127.0.0.1:5600 x'), isFalse);
    expect(isAdbDisconnect(emulatorDrop), isTrue);
    expect(isAdbDisconnect(tcpDrop), isTrue);
    expect(
      isAdbDisconnect('I adb : main.cpp:65 Android Debug Bridge'),
      isFalse,
    );
    expect(isAdbDisconnect(emulatorDrop, serial: '127.0.0.1:5600'), isFalse);
    expect(isAdbDisconnect(tcpDrop, serial: '127.0.0.1:5600'), isTrue);
  });
}
