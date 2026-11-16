// DIR/config.json (written by prepare) and the private files of a session.
import 'dart:convert';
import 'dart:io';

import 'contract.dart';

/// What `prepare` decided, for `boot` and the daemon.
final class EmulatorConfig {
  const EmulatorConfig({
    required this.avd,
    required this.avdHome,
    required this.image,
    required this.gpu,
    required this.extraArguments,
    required this.bootTimeout,
    required this.switches,
  });

  factory EmulatorConfig.fromJson(Map<String, Object?> json) {
    if (json['schemaVersion'] != kSchemaVersion) {
      throw const FormatException('Unknown config.json schema.');
    }
    return EmulatorConfig(
      avd: json['avd'] as String,
      avdHome: json['avdHome'] as String,
      image: json['image'] as String,
      gpu: json['gpu'] as String,
      extraArguments: (json['extraArguments'] as List).cast<String>(),
      bootTimeout: Duration(seconds: json['bootTimeoutSeconds'] as int),
      switches: Switches.fromJson(
        (json['switches'] as Map).cast<String, Object?>(),
      ),
    );
  }

  static File file(Directory session) => File('${session.path}/config.json');

  static EmulatorConfig read(Directory session) {
    final source = file(session);
    if (!source.existsSync()) {
      throw const FormatException('No config.json: run prepare first.');
    }
    return EmulatorConfig.fromJson(readJson(source));
  }

  final String avd;
  final String avdHome;

  /// The sdkmanager package of the system image.
  final String image;
  final String gpu;
  final List<String> extraArguments;
  final Duration bootTimeout;
  final Switches switches;

  Map<String, Object?> toJson() => {
    'schemaVersion': kSchemaVersion,
    'avd': avd,
    'avdHome': avdHome,
    'image': image,
    'gpu': gpu,
    'extraArguments': extraArguments,
    'bootTimeoutSeconds': bootTimeout.inSeconds,
    'switches': switches.toJson(),
  };

  void write(Directory session) =>
      writeAtomically(file(session), '${jsonEncode(toJson())}\n');
}

/// The files of a session directory.
extension SessionFiles on Directory {
  File get owned => File('$path/owned.json');
  File get emulatorPid => File('$path/emulator.pid');
  File get emulatorExit => File('$path/emulator-exit.json');
  File get stopRequested => File('$path/stop-requested');
  File get emulatorLog => File('$path/emulator.log');
  File get logcat => File('$path/logcat.txt');
  File get adbServerLog => File('$path/adb-server.log');
  File get hostLoad => File('$path/host-load.txt');
  File get hostDiagnostics => File('$path/host-diagnostics.txt');
  File get daemonLog => File('$path/daemon.log');
}

/// The evidence of one attempt. `run` moves these into the attempt
/// directory after it stops the emulator.
const kEvidenceFiles = [
  'emulator.log',
  'logcat.txt',
  'logcat-dump.txt',
  'adb-server.log',
  'host-load.txt',
  'host-diagnostics.txt',
  'device-diagnostics.txt',
  'emulator-exit.json',
  'daemon.log',
];
