// The detached process that owns the emulator of one session. It writes
// DIR/emulator-exit.json when the emulator stops and no stop was asked.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'config.dart';
import 'contract.dart';
import 'diagnostics.dart';
import 'emulator.dart';
import 'host.dart';
import 'process_tree.dart';

Future<int> runDaemon(Host host, Directory session, int port) async {
  final config = EmulatorConfig.read(session);
  final log = session.daemonLog.openWrite(mode: FileMode.append);
  final output = session.emulatorLog.openWrite(mode: FileMode.append);
  final stopped = Completer<void>();
  var stopping = false;
  final signals = <StreamSubscription<ProcessSignal>>[];
  try {
    await hostSnapshot(host, session.hostDiagnostics, 'before_emulator');
    final command = emulatorCommand(
      host.sdk,
      config.avd,
      gpu: config.gpu,
      adbTrace: config.switches.adbTrace,
      debugger: config.switches.gdb,
      extra: ['-port', '$port', ...config.extraArguments],
    );
    final Process child;
    try {
      child = await Process.start(
        command.first,
        command.skip(1).toList(),
        environment: {...host.environment, 'ANDROID_AVD_HOME': config.avdHome},
        includeParentEnvironment: false,
      );
    } on ProcessException {
      _exited(session, 127);
      log.writeln(Marker.emulatorExit.line('the emulator could not start'));
      return 127;
    }
    writeAtomically(session.emulatorPid, '${child.pid}\n');
    for (final signal in [ProcessSignal.sigterm, ProcessSignal.sigint]) {
      signals.add(
        signal.watch().listen((_) {
          stopping = true;
          unawaited(stopProcessTree(child.pid, ProcessSignal.sigkill));
        }),
      );
    }
    final outDone = child.stdout.listen(output.add).asFuture<void>();
    final errDone = child.stderr.listen(output.add).asFuture<void>();
    await hostSnapshot(
      host,
      session.hostDiagnostics,
      'emulator_started',
      pid: child.pid,
    );
    unawaited(_sideTasks(host, session, stopped.future));
    final code = await child.exitCode;
    await Future.wait([
      outDone,
      errDone,
    ]).timeout(const Duration(seconds: 10), onTimeout: () => []);
    await output.flush();
    if (!stopping && !session.stopRequested.existsSync()) {
      await hostSnapshot(host, session.hostDiagnostics, 'emulator_exit');
      // GDB has written its frames; only now publish the exit. Exit 0 is
      // also unexpected while a session owns the emulator.
      _exited(session, code);
      log.writeln(
        Marker.emulatorExit.line(
          '${config.switches.gdb ? 'debugger' : 'emulator'} exit $code',
        ),
      );
    }
    return code;
  } finally {
    stopped.complete();
    for (final subscription in signals) {
      await subscription.cancel();
    }
    await output.close();
    await log.close();
  }
}

void _exited(Directory session, int code) => writeAtomically(
  session.emulatorExit,
  '${jsonEncode({'exitCode': code})}\n',
);

/// Logcat and host load, from the time that boot wrote session.json.
Future<void> _sideTasks(
  Host host,
  Directory session,
  Future<void> stopped,
) async {
  var done = false;
  unawaited(stopped.then((_) => done = true));
  while (!done && !Session.file(session).existsSync()) {
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  if (done) return;
  final serial = Session.read(session)!.serial;
  await Future.wait([
    captureLogcat(host, serial, session.logcat, stopped),
    sampleHostLoad(host, serial, session.hostLoad, stopped),
  ]);
}
