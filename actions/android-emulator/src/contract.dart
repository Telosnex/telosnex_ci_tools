// The contract of android.dart: the files it writes, its markers, its exit
// codes and its switches. README.md of this action describes the same.
import 'dart:convert';
import 'dart:io';

const kSchemaVersion = 1;

/// Wrong configuration or a launcher error.
const kExitConfig = 2;

/// The attempt took too long.
const kExitTimeout = 124;

/// An infrastructure failure, also a retry that was not allowed or failed.
const kExitInfrastructure = 125;

/// Only inside `run`: adb lost the device before the first test. Never
/// returned.
const kExitRetryable = 75;

/// I7: no retry after a first attempt of this length or more.
const kRetryWindow = Duration(seconds: 900);

/// The prefix before `:` is the contract, the label goes into result.json.
enum Marker {
  adbDisconnect('ANDROID_ADB_DISCONNECT', 'android-adb-disconnect'),
  emulatorExit('ANDROID_EMULATOR_EXIT', 'android-emulator-exit'),
  deviceOffline('ANDROID_DEVICE_OFFLINE', 'android-device-offline'),
  startupTimeout(
    'ANDROID_TEST_STARTUP_TIMEOUT',
    'android-test-startup-timeout',
  );

  const Marker(this.prefix, this.label);
  final String prefix;
  final String label;

  String line(String text) => '$prefix: $text';
}

/// Writes [text] to [file] through a temporary file and a rename, so a reader
/// never sees half a file.
void writeAtomically(File file, String text) {
  file.parent.createSync(recursive: true);
  final temporary = File('${file.path}.tmp');
  temporary.writeAsStringSync(text, flush: true);
  temporary.renameSync(file.path);
}

Map<String, Object?> readJson(File file) =>
    (jsonDecode(file.readAsStringSync()) as Map).cast<String, Object?>();

/// DIR/session.json, written by `boot`.
final class Session {
  const Session({
    required this.consoleSerial,
    required this.serial,
    required this.abi,
  });

  factory Session.fromJson(Map<String, Object?> json) {
    if (json['schemaVersion'] != kSchemaVersion) {
      throw const FormatException('Unknown session.json schema.');
    }
    return Session(
      consoleSerial: json['consoleSerial'] as String,
      serial: json['serial'] as String,
      abi: json['abi'] as String,
    );
  }

  static File file(Directory session) => File('${session.path}/session.json');

  static Session? read(Directory session) {
    final source = file(session);
    return source.existsSync() ? Session.fromJson(readJson(source)) : null;
  }

  /// The serial of the emulator console, for `adb emu`.
  final String consoleSerial;

  /// The serial for tests: the console serial, or 127.0.0.1:PORT over TCP.
  final String serial;
  final String abi;

  Map<String, Object?> toJson() => {
    'schemaVersion': kSchemaVersion,
    'consoleSerial': consoleSerial,
    'serial': serial,
    'abi': abi,
  };

  void write(Directory session) =>
      writeAtomically(file(session), '${jsonEncode(toJson())}\n');
}

/// The switches of section 5 of ADR 023 of the app. An action input wins,
/// then the environment variable, then the default.
final class Switches {
  const Switches({
    this.gdb = true,
    this.adbTrace = false,
    this.cores = 4,
    this.tcp = false,
    this.ramMb = 4096,
  });

  /// [inputs] has the action inputs; an empty value is no input.
  factory Switches.resolve(
    Map<String, String> inputs,
    Map<String, String> environment,
  ) {
    String? pick(String input, [String? variable]) {
      final value = inputs[input] ?? '';
      if (value.isNotEmpty) return value;
      final fromEnvironment = variable == null ? '' : environment[variable];
      return fromEnvironment == null || fromEnvironment.isEmpty
          ? null
          : fromEnvironment;
    }

    final gdb = pick('gdb', 'TELOSNEX_ANDROID_GDB');
    final trace = pick('adb-trace', 'TELOSNEX_ANDROID_ADB_TRACE');
    final transport = pick('adb-transport') ?? 'emulator';
    if (transport != 'emulator' && transport != 'tcp') {
      throw const FormatException('adb-transport is emulator or tcp.');
    }
    return Switches(
      // Only false turns GDB off; only true turns the trace on.
      gdb: gdb != 'false',
      adbTrace: trace == 'true',
      cores: _count(
        pick('cores', 'TELOSNEX_ANDROID_EMULATOR_CORES'),
        'cores',
        4,
        1,
        16,
      ),
      tcp: transport == 'tcp',
      ramMb: _count(pick('ram-mb'), 'ram-mb', 4096, 512, 65536),
    );
  }

  factory Switches.fromJson(Map<String, Object?> json) => Switches(
    gdb: json['gdb'] as bool,
    adbTrace: json['adbTrace'] as bool,
    cores: json['cores'] as int?,
    tcp: json['tcp'] as bool,
    ramMb: json['ramMb'] as int?,
  );

  final bool gdb;
  final bool adbTrace;

  /// Null keeps the value of the AVD.
  final int? cores;
  final bool tcp;

  /// Null keeps the value of the AVD.
  final int? ramMb;

  Map<String, Object?> toJson() => {
    'gdb': gdb,
    'adbTrace': adbTrace,
    'cores': cores,
    'tcp': tcp,
    'ramMb': ramMb,
  };
}

int? _count(String? value, String name, int fallback, int min, int max) {
  if (value == null) return fallback;
  if (value == 'default') return null;
  final number = int.tryParse(value);
  if (number == null || number < min || number > max) {
    throw FormatException('$name is default, or $min to $max.');
  }
  return number;
}

/// One attempt of `run`, in result.json.
final class AttemptResult {
  const AttemptResult({
    required this.attempt,
    required this.exitCode,
    required this.elapsed,
    required this.markers,
    required this.testStarted,
    required this.emulatorStopped,
    required this.evidence,
  });

  factory AttemptResult.fromJson(Map<String, Object?> json) => AttemptResult(
    attempt: json['attempt'] as int,
    exitCode: json['exitCode'] as int,
    elapsed: Duration(milliseconds: json['elapsedMs'] as int),
    markers: (json['markers'] as List).cast<String>(),
    testStarted: json['testStarted'] as bool,
    emulatorStopped: json['emulatorStopped'] as bool,
    evidence: (json['evidence'] as List).cast<String>(),
  );

  final int attempt;

  /// The exit code of this attempt, 75 included.
  final int exitCode;
  final Duration elapsed;

  /// [Marker.label]s.
  final List<String> markers;
  final bool testStarted;

  /// The emulator stopped when no stop was asked.
  final bool emulatorStopped;

  /// Paths relative to the run directory.
  final List<String> evidence;

  Map<String, Object?> toJson() => {
    'attempt': attempt,
    'exitCode': exitCode,
    'elapsedMs': elapsed.inMilliseconds,
    'markers': markers,
    'testStarted': testStarted,
    'emulatorStopped': emulatorStopped,
    'evidence': evidence,
  };
}

/// RUN_DIR/result.json. Only fixed fields: never environment values, VM
/// service URIs, command lines or log lines.
final class RunResult {
  const RunResult({
    required this.exitCode,
    required this.elapsed,
    required this.attempts,
  });

  factory RunResult.fromJson(Map<String, Object?> json) {
    if (json['schemaVersion'] != kSchemaVersion) {
      throw const FormatException('Unknown result.json schema.');
    }
    return RunResult(
      exitCode: json['exitCode'] as int,
      elapsed: Duration(milliseconds: json['elapsedMs'] as int),
      attempts: [
        for (final attempt in json['attempts'] as List)
          AttemptResult.fromJson((attempt as Map).cast<String, Object?>()),
      ],
    );
  }

  static File file(Directory run) => File('${run.path}/result.json');

  static RunResult read(Directory run) =>
      RunResult.fromJson(readJson(file(run)));

  final int exitCode;
  final Duration elapsed;
  final List<AttemptResult> attempts;

  Map<String, Object?> toJson() => {
    'schemaVersion': kSchemaVersion,
    'exitCode': exitCode,
    'elapsedMs': elapsed.inMilliseconds,
    'attempts': [for (final attempt in attempts) attempt.toJson()],
  };

  void write(Directory run) => writeAtomically(
    file(run),
    '${const JsonEncoder.withIndent('  ').convert(toJson())}\n',
  );
}
