// Bounded diagnostics of the host and the device. Nothing here records a
// process command line.
import 'dart:async';
import 'dart:io';

import 'emulator.dart';
import 'host.dart';

String _now() => DateTime.now().toUtc().toIso8601String();

/// Appends host memory state, and with [pid] the state of that process.
Future<void> hostSnapshot(
  Host host,
  File output,
  String phase, {
  int? pid,
}) async {
  final text = StringBuffer('===== $phase ${_now()} =====\n');
  for (final path in [
    '/proc/meminfo',
    '/proc/pressure/memory',
    '/sys/fs/cgroup/memory.events',
    if (pid != null) '/proc/$pid/status',
  ]) {
    text.writeln('--- $path');
    try {
      text.writeln(await File(path).readAsString());
    } on FileSystemException {
      text.writeln('unavailable');
    }
  }
  text.writeln('--- ${host.kvm}');
  try {
    final stat = File(host.kvm).statSync();
    text.writeln('mode=${stat.modeString()} changed=${stat.changed.toUtc()}');
  } on Object {
    text.writeln('unavailable');
  }
  final acl = await host.run('getfacl', ['-p', host.kvm]);
  if (acl.ok) text.write(acl.stdout);
  final emulators = await host.run('pgrep', ['-f', 'emulator/qemu/']);
  text.writeln(
    '--- emulator processes: ${emulators.ok ? emulators.stdout.trim().split('\n').length : 0}',
  );
  await output.writeAsString('$text\n', mode: FileMode.append, flush: true);
}

/// Appends the state of [serial] to OUTPUT/device-diagnostics.txt. With
/// [afterFailure], it first waits briefly for adb to come back, then saves
/// the whole guest log buffer to OUTPUT/logcat-dump.txt: that buffer
/// outlives an adb disconnect.
Future<void> deviceDiagnostics(
  Host host,
  String? serial,
  Directory output,
  String phase, {
  bool afterFailure = false,
}) async {
  output.createSync(recursive: true);
  final id = serial != null && isDeviceSerial(serial) ? serial : null;
  var state = '';
  if (id != null) {
    if (afterFailure) {
      await host.device(id, [
        'wait-for-device',
      ], timeout: const Duration(seconds: 15));
    }
    state = (await host.device(id, [
      'get-state',
    ], timeout: const Duration(seconds: 5))).line;
  }
  final text = StringBuffer('===== $phase ${_now()} =====\n');
  // A new pid or start time means that the adb server restarted.
  final server = await host.run('ps', ['-C', 'adb', '-o', 'pid=,lstart=']);
  text
    ..writeln('--- adb server process')
    ..write(server.ok ? server.stdout : 'none\n')
    ..writeln('--- adb devices -l')
    ..write((await host.adbCommand(['devices', '-l'])).stdout);
  if (id != null && state != 'device') {
    text.writeln(
      '--- $id state: ${state.isEmpty ? 'none' : state}; '
      'device queries skipped',
    );
  } else if (id != null) {
    for (final (title, command, seconds) in [
      (
        'abi, boot, guest nproc and loadavg',
        r'echo ro.product.cpu.abi=$(getprop ro.product.cpu.abi); '
            r'echo sys.boot_completed=$(getprop sys.boot_completed); '
            r'echo nproc=$(nproc); echo loadavg=$(cat /proc/loadavg)',
        10,
      ),
      ('df -h', 'df -h', 10),
      ('dumpsys meminfo', 'dumpsys meminfo', 20),
      ('dumpsys activity processes', 'dumpsys activity processes', 20),
    ]) {
      final result = await host.device(id, [
        'shell',
        command,
      ], timeout: Duration(seconds: seconds));
      text
        ..writeln('--- $title')
        ..write(result.stdout);
    }
  }
  await File(
    '${output.path}/device-diagnostics.txt',
  ).writeAsString('$text\n', mode: FileMode.append, flush: true);
  if (afterFailure && id != null && state == 'device') {
    final dump = await host.device(id, [
      'logcat',
      '-d',
      '-v',
      'threadtime',
    ], timeout: const Duration(seconds: 30));
    await File('${output.path}/logcat-dump.txt').writeAsString(
      '===== $phase logcat dump ${_now()} =====\n${dump.stdout}',
      mode: FileMode.append,
      flush: true,
    );
  }
}

final _logcatTime = RegExp(
  r'^(\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3})',
  multiLine: true,
);

/// The last logcat timestamp in the end of [file], for `logcat -T`.
String? lastLogcatTime(File file) {
  if (!file.existsSync()) return null;
  final length = file.lengthSync();
  final handle = file.openSync();
  try {
    final start = length > 16384 ? length - 16384 : 0;
    handle.setPositionSync(start);
    final tail = String.fromCharCodes(handle.readSync(length - start));
    return _logcatTime.allMatches(tail).lastOrNull?[1];
  } finally {
    handle.closeSync();
  }
}

/// Captures the guest logcat into [output] until [stopped] completes. adb
/// logcat exits when the connection drops; the capture starts again from
/// the last timestamp when adb is back. Lines of that timestamp can repeat.
Future<void> captureLogcat(
  Host host,
  String serial,
  File output,
  Future<void> stopped,
) async {
  var done = false;
  Process? child;
  unawaited(
    stopped.then((_) {
      done = true;
      child?.kill(ProcessSignal.sigkill);
    }),
  );
  while (!done) {
    final since = lastLogcatTime(output);
    final sink = output.openWrite(mode: FileMode.append);
    try {
      final process = child = await Process.start(host.adb, [
        '-s',
        serial,
        'logcat',
        '-v',
        'threadtime',
        if (since != null) ...['-T', since],
      ], environment: host.environment);
      final out = process.stdout.listen(sink.add).asFuture<void>();
      final err = process.stderr.listen(sink.add).asFuture<void>();
      await process.exitCode;
      await Future.wait([
        out,
        err,
      ]).timeout(const Duration(seconds: 2), onTimeout: () => []);
      if (!done) {
        sink.writeln(
          '===== logcat capture exited ${_now()}; '
          'restarting when adb reconnects =====',
        );
      }
    } on ProcessException {
      done = true;
    } finally {
      await sink.close();
    }
    if (done) break;
    final waited = await host.device(serial, [
      'wait-for-device',
    ], timeout: const Duration(seconds: 30));
    if (!waited.ok) await Future<void>.delayed(const Duration(seconds: 2));
  }
}

/// One line about every second until [stopped]: local time, 1-minute load,
/// CPU and I/O pressure (some avg10), the host CPU split in percent (user,
/// system, iowait, steal, idle), the emulator CPU in percent of one core,
/// the round trip of one `adb shell` in ms, the guest 1-minute load, the
/// KVM change time and whether the job can open KVM. A rising round trip is
/// the adb stall itself.
Future<void> sampleHostLoad(
  Host host,
  String serial,
  File output,
  Future<void> stopped,
) async {
  if (!File('/proc/stat').existsSync()) return;
  var done = false;
  unawaited(stopped.then((_) => done = true));
  final cores = Platform.numberOfProcessors;
  final sink = output.openWrite(mode: FileMode.append);
  sink.writeln(
    '# time load1 cpu_some10 io_some10 user% sys% iowait% steal% idle% '
    'qemu%_of_one_core adb_ms guest_load1 kvm_change kvm_rw '
    '(host cores: $cores)',
  );
  var previous = _cpu();
  var previousQemu = await _qemuTicks(host);
  try {
    while (!done) {
      await Future<void>.delayed(const Duration(seconds: 1));
      final watch = Stopwatch()..start();
      final probe = await host.device(serial, [
        'shell',
        'cat',
        '/proc/loadavg',
      ], timeout: const Duration(seconds: 5));
      final roundTrip = probe.ok ? '${watch.elapsedMilliseconds}' : 'fail';
      final guest = probe.ok ? probe.line.split(' ').first : '-';
      final now = _cpu();
      final qemu = await _qemuTicks(host);
      final total = (now.total - previous.total) <= 0
          ? 1
          : now.total - previous.total;
      int percent(int a, int b) => 100 * (a - b) ~/ total;
      final idle =
          total -
          (now.user - previous.user) -
          (now.system - previous.system) -
          (now.iowait - previous.iowait) -
          (now.steal - previous.steal);
      // A restarted emulator resets its counter: 0 for that interval.
      final qemuDelta = qemu - previousQemu < 0 ? 0 : qemu - previousQemu;
      var kvmChange = '-';
      var kvmOpen = 'no';
      try {
        kvmChange =
            '${File(host.kvm).statSync().changed.millisecondsSinceEpoch ~/ 1000}';
      } on Object {
        // The column stays '-'.
      }
      try {
        File(host.kvm).openSync(mode: FileMode.append).closeSync();
        kvmOpen = 'yes';
      } on Object {
        // The column stays 'no'.
      }
      final time = DateTime.now();
      String two(int n) => n.toString().padLeft(2, '0');
      sink.writeln(
        [
          '${two(time.month)}-${two(time.day)} ${two(time.hour)}:'
              '${two(time.minute)}:${two(time.second)}.'
              '${time.millisecond.toString().padLeft(3, '0')}',
          _firstField('/proc/loadavg'),
          _pressure('/proc/pressure/cpu'),
          _pressure('/proc/pressure/io'),
          percent(now.user, previous.user),
          percent(now.system, previous.system),
          percent(now.iowait, previous.iowait),
          percent(now.steal, previous.steal),
          100 * idle ~/ total,
          100 * qemuDelta * cores ~/ total,
          roundTrip,
          guest,
          kvmChange,
          kvmOpen,
        ].join(' '),
      );
      previous = now;
      previousQemu = qemu;
    }
  } finally {
    await sink.close();
  }
}

typedef _Cpu = ({int user, int system, int iowait, int steal, int total});

_Cpu _cpu() {
  try {
    final fields = File('/proc/stat')
        .readAsLinesSync()
        .firstWhere((line) => line.startsWith('cpu '))
        .split(RegExp(r'\s+'))
        .skip(1)
        .map(int.parse)
        .toList();
    int at(int i) => i < fields.length ? fields[i] : 0;
    return (
      user: at(0) + at(1),
      system: at(2) + at(5) + at(6),
      iowait: at(4),
      steal: at(7),
      total: [for (var i = 0; i < 8; i++) at(i)].reduce((a, b) => a + b),
    );
  } on Object {
    return (user: 0, system: 0, iowait: 0, steal: 0, total: 0);
  }
}

Future<int> _qemuTicks(Host host) async {
  final found = await host.run('pgrep', ['-o', '-f', 'emulator/qemu/']);
  final pid = int.tryParse(found.line);
  if (pid == null) return 0;
  try {
    final text = File('/proc/$pid/stat').readAsStringSync();
    final fields = text.substring(text.lastIndexOf(')') + 2).split(' ');
    // utime and stime are fields 14 and 15; the state is field 3.
    return int.parse(fields[11]) + int.parse(fields[12]);
  } on Object {
    return 0;
  }
}

String _firstField(String path) {
  try {
    return File(path).readAsStringSync().split(' ').first;
  } on Object {
    return '-';
  }
}

String _pressure(String path) {
  try {
    final some = File(
      path,
    ).readAsLinesSync().firstWhere((line) => line.startsWith('some'));
    return RegExp(r'avg10=([0-9.]+)').firstMatch(some)?[1] ?? '-';
  } on Object {
    return '-';
  }
}
