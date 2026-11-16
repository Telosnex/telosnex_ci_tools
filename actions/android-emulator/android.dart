// The Android emulator tool of telosnex_ci_tools. Only dart: imports, so it
// runs with `dart android.dart` and no pub get. See README.md.
//
//   prepare     --session DIR [inputs]
//   boot        --session DIR [--fresh]
//   run         --session DIR --run-dir DIR [--startup-protocol flutter-machine]
//               [--timeout-minutes N] -- COMMAND ARG...
//   stop        --session DIR
//   diagnostics --session DIR --output-dir DIR --phase NAME [--after-failure]
import 'dart:io';

import 'src/contract.dart';
import 'src/daemon.dart';
import 'src/diagnostics.dart';
import 'src/emulator.dart';
import 'src/host.dart';
import 'src/lifecycle.dart';
import 'src/supervisor.dart';

const _valued = {
  '--session',
  '--run-dir',
  '--output-dir',
  '--phase',
  '--port',
  '--startup-protocol',
  '--timeout-minutes',
  '--api-level',
  '--target',
  '--device',
  '--gpu',
  '--emulator-args',
  '--boot-timeout-minutes',
  '--avd',
  '--gdb',
  '--adb-trace',
  '--cores',
  '--adb-transport',
  '--ram-mb',
};
const _flags = {'--fresh', '--after-failure'};

Future<void> main(List<String> arguments) async {
  final host = Host.fromEnvironment(Platform.environment);
  final tool = Platform.script.toFilePath();
  try {
    if (arguments.isEmpty) throw const FormatException('No command.');
    final command = arguments.first;
    final separator = arguments.indexOf('--');
    final words = arguments.sublist(
      1,
      separator < 0 ? arguments.length : separator,
    );
    final rest = separator < 0 ? <String>[] : arguments.sublist(separator + 1);
    final options = <String, String>{};
    for (var i = 0; i < words.length; i++) {
      final word = words[i];
      if (_flags.contains(word)) {
        options[word] = 'true';
      } else if (_valued.contains(word) && i + 1 < words.length) {
        options[word] = words[++i];
      } else {
        throw FormatException('Unknown argument: $word');
      }
    }
    String need(String name) =>
        options[name] ?? (throw FormatException('$name is required.'));
    final session = Directory(need('--session'));
    switch (command) {
      case 'prepare':
        await prepare(host, session, _prepareInputs(options, host));
      case 'boot':
        final ready = await boot(
          host,
          session,
          tool: tool,
          fresh: options.containsKey('--fresh'),
        );
        stdout.writeln('Serial: ${ready.serial}');
        host.githubFile('GITHUB_OUTPUT', 'serial=${ready.serial}');
      case 'run':
        if (rest.isEmpty) throw const FormatException('No command after --.');
        final protocol = options['--startup-protocol'];
        if (protocol != null && protocol != 'flutter-machine') {
          throw const FormatException('--startup-protocol is flutter-machine.');
        }
        final minutes = int.tryParse(options['--timeout-minutes'] ?? '70');
        if (minutes == null || minutes < 1) {
          throw const FormatException('--timeout-minutes is a count.');
        }
        exitCode = await runSupervised(
          host,
          session,
          Directory(need('--run-dir')),
          rest,
          tool: tool,
          flutterMachine: protocol != null,
          timeout: Duration(minutes: minutes),
        );
      case 'stop':
        await stop(host, session);
      case 'diagnostics':
        await deviceDiagnostics(
          host,
          Session.read(session)?.serial,
          Directory(need('--output-dir')),
          need('--phase'),
          afterFailure: options.containsKey('--after-failure'),
        );
      case '_daemon':
        // The event loop has timers of the side tasks: exit at once.
        exit(await runDaemon(host, session, int.parse(need('--port'))));
      default:
        throw FormatException('Unknown command: $command');
    }
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    exitCode = kExitConfig;
  } on LifecycleException catch (error) {
    stderr.writeln(error.message);
    exitCode = kExitInfrastructure;
  }
  // Pending timers of a failed step must not hold the process.
  await stdout.flush();
  exit(exitCode);
}

PrepareInputs _prepareInputs(Map<String, String> options, Host host) {
  String value(String name, String fallback) {
    final given = options[name] ?? '';
    return given.isEmpty ? fallback : given;
  }

  final minutes = int.tryParse(value('--boot-timeout-minutes', '15'));
  if (minutes == null || minutes < 1) {
    throw const FormatException('boot-timeout-minutes is a count.');
  }
  final avd = value('--avd', 'ci');
  if (!RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(avd)) {
    throw const FormatException('Bad AVD name.');
  }
  return PrepareInputs(
    apiLevel: value('--api-level', '35'),
    target: value('--target', 'google_apis'),
    device: value('--device', 'pixel_6'),
    gpu: value('--gpu', 'swiftshader_indirect'),
    emulatorArguments: splitArguments(options['--emulator-args'] ?? ''),
    bootTimeout: Duration(minutes: minutes),
    avd: avd,
    switches: Switches.resolve({
      for (final name in [
        'gdb',
        'adb-trace',
        'cores',
        'adb-transport',
        'ram-mb',
      ])
        name: options['--$name'] ?? '',
    }, host.environment),
  );
}
