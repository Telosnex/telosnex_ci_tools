// How the tool runs commands, and the timings it uses. Tests replace the
// timings and the KVM path, and put fake commands on PATH and in the SDK.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'process_tree.dart';

final class CommandResult {
  const CommandResult(this.exitCode, this.stdout, this.stderr);

  /// -1 after a timeout.
  final int exitCode;
  final String stdout;
  final String stderr;

  bool get ok => exitCode == 0;

  /// The first line of stdout without the carriage return of adb.
  String get line =>
      const LineSplitter().convert(stdout).firstOrNull?.trim() ?? '';
}

final class Host {
  Host({
    required this.environment,
    this.kvm = '/dev/kvm',
    this.checkPlatform = true,
    this.poll = const Duration(seconds: 5),
    this.settleChecks = 12,
    this.healthInterval = const Duration(seconds: 2),
    this.startupTimeout = const Duration(minutes: 2),
    this.terminationGrace = const Duration(seconds: 10),
    this.retryWindow = const Duration(seconds: 900),
    this.tcpTries = 20,
    this.tcpPause = const Duration(seconds: 3),
    this.installPause = const Duration(seconds: 30),
    this.diagnosticsTimeout = const Duration(seconds: 90),
  });

  /// The real host, or with TELOSNEX_ANDROID_TOOL_TEST=1 the short timings
  /// and the fake KVM device of the tests.
  factory Host.fromEnvironment(Map<String, String> environment) {
    if (environment['TELOSNEX_ANDROID_TOOL_TEST'] != '1') {
      return Host(environment: environment);
    }
    const short = Duration(milliseconds: 50);
    return Host(
      environment: environment,
      kvm: environment['TELOSNEX_ANDROID_TOOL_TEST_KVM'] ?? '/dev/null',
      checkPlatform: false,
      poll: short,
      settleChecks: 2,
      healthInterval: short,
      startupTimeout: Duration(
        milliseconds: int.parse(
          environment['TELOSNEX_ANDROID_TOOL_TEST_STARTUP_MS'] ?? '2000',
        ),
      ),
      terminationGrace: const Duration(seconds: 2),
      retryWindow: Duration(
        milliseconds: int.parse(
          environment['TELOSNEX_ANDROID_TOOL_TEST_RETRY_WINDOW_MS'] ?? '900000',
        ),
      ),
      tcpTries: 3,
      tcpPause: short,
      installPause: short,
      diagnosticsTimeout: const Duration(seconds: 5),
    );
  }

  final Map<String, String> environment;
  final String kvm;
  final bool checkPlatform;
  final Duration poll;

  /// Readiness needs this many good checks in a row, [poll] apart: 60 s.
  final int settleChecks;
  final Duration healthInterval;
  final Duration startupTimeout;
  final Duration terminationGrace;
  final Duration retryWindow;
  final int tcpTries;
  final Duration tcpPause;
  final Duration installPause;
  final Duration diagnosticsTimeout;

  String get sdk {
    final sdk = environment['ANDROID_HOME'] ?? environment['ANDROID_SDK_ROOT'];
    if (sdk == null || sdk.isEmpty) {
      throw const FormatException('ANDROID_HOME is not set.');
    }
    return sdk;
  }

  /// adb of the SDK; on ubuntu-24.04 it is not on PATH.
  String get adb {
    final path = '$sdk/platform-tools/adb';
    return File(path).existsSync() ? path : 'adb';
  }

  /// Runs [executable] and returns its output. After [timeout] it stops the
  /// process tree and returns exit -1.
  Future<CommandResult> run(
    String executable,
    List<String> arguments, {
    Duration timeout = const Duration(seconds: 30),
    String? input,
    Map<String, String> extraEnvironment = const {},
  }) async {
    final Process process;
    try {
      process = await Process.start(
        executable,
        arguments,
        environment: {...environment, ...extraEnvironment},
        includeParentEnvironment: false,
      );
    } on ProcessException catch (error) {
      return CommandResult(127, '', error.message);
    }
    final out = process.stdout.transform(utf8.decoder).join();
    final err = process.stderr.transform(utf8.decoder).join();
    if (input != null) process.stdin.write(input);
    // A command that does not read stdin can close it first.
    unawaited(process.stdin.close().catchError((_) {}));
    final code = await process.exitCode.timeout(
      timeout,
      onTimeout: () async {
        await stopProcessTree(process.pid, ProcessSignal.sigkill);
        return -1;
      },
    );
    // A child that keeps the pipes open must not hold the result.
    final drained = await Future.wait([
      out,
      err,
    ]).timeout(const Duration(seconds: 2), onTimeout: () => ['', '']);
    return CommandResult(code, drained[0], drained[1]);
  }

  Future<CommandResult> adbCommand(
    List<String> arguments, {
    Duration timeout = const Duration(seconds: 10),
  }) => run(adb, arguments, timeout: timeout);

  /// `adb -s SERIAL ARGS`.
  Future<CommandResult> device(
    String serial,
    List<String> arguments, {
    Duration timeout = const Duration(seconds: 10),
  }) => adbCommand(['-s', serial, ...arguments], timeout: timeout);

  Future<String> property(String serial, String name) async =>
      (await device(serial, ['shell', 'getprop', name])).line;

  /// Writes `NAME=VALUE` to the GitHub file named by [variable], if it is set.
  void githubFile(String variable, String line) {
    final path = environment[variable];
    if (path == null || path.isEmpty) return;
    File(path).writeAsStringSync('$line\n', mode: FileMode.append);
  }
}
