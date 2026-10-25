// Runs a command, and stops it when it prints nothing for a time.
//
//   dart watch.dart --idle <seconds> [--ignore <regex>] [--on-stall <cmd>]
//       -- <command> [<args>...]
//
// A test command that waits forever (an app that never connects, a page that
// never loads) prints nothing until the job times out. This stops it after
// --idle seconds without output, runs --on-stall first (a shell command that
// saves diagnostics), and exits 124, as timeout(1). Otherwise the exit code
// is the command's.
//
// --ignore: lines that match do not count as output (verbose log lines that
// a stalled tool still prints).
//
// This file uses only dart:io and dart:async: actions/watch runs it without
// a pub get. test/watch_test.dart imports it.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// The exit code after a stall, as timeout(1).
const stallExitCode = 124;

Future<void> main(List<String> arguments) async {
  final WatchOptions options;
  try {
    options = WatchOptions.parse(arguments);
  } on FormatException catch (e) {
    stderr
      ..writeln('watch: ${e.message}')
      ..writeln(
        'Usage: dart watch.dart --idle <seconds> [--ignore <regex>] '
        '[--on-stall <cmd>] -- <command> [<args>...]',
      );
    exit(64);
  }
  exit(await watch(options));
}

class WatchOptions {
  final Duration idle;
  final RegExp? ignore;
  final String? onStall;
  final List<String> command;

  WatchOptions({
    required this.idle,
    required this.command,
    this.ignore,
    this.onStall,
  });

  factory WatchOptions.parse(List<String> args) {
    final split = args.indexOf('--');
    if (split < 0 || split == args.length - 1) {
      throw const FormatException('No command after --.');
    }
    final options = args.sublist(0, split);
    final command = args.sublist(split + 1);
    Duration? idle;
    RegExp? ignore;
    String? onStall;
    for (var i = 0; i < options.length; i++) {
      String value() {
        if (i + 1 >= options.length) {
          throw FormatException('${options[i]} needs a value.');
        }
        return options[++i];
      }

      switch (options[i]) {
        case '--idle':
          final v = value();
          final seconds = int.tryParse(v);
          if (seconds == null || seconds <= 0) {
            throw FormatException('--idle $v: not a number of seconds.');
          }
          idle = Duration(seconds: seconds);
        case '--ignore':
          final v = value();
          if (v.isNotEmpty) ignore = RegExp(v);
        case '--on-stall':
          final v = value();
          if (v.isNotEmpty) onStall = v;
        default:
          throw FormatException('Unknown option ${options[i]}.');
      }
    }
    if (idle == null) throw const FormatException('--idle is required.');
    return WatchOptions(
      idle: idle,
      command: command,
      ignore: ignore,
      onStall: onStall,
    );
  }
}

/// Runs [options.command] and returns its exit code, or [stallExitCode].
Future<int> watch(
  WatchOptions options, {
  IOSink? out,
  IOSink? err,
  Duration tick = const Duration(seconds: 1),
}) async {
  out ??= stdout;
  err ??= stderr;
  final process = await Process.start(
    options.command.first,
    options.command.sublist(1),
    runInShell: Platform.isWindows,
  );
  var lastOutput = DateTime.now();
  final done = <Future<void>>[];
  for (final (stream, sink) in [(process.stdout, out), (process.stderr, err)]) {
    done.add(
      stream
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .forEach((line) {
            sink.writeln(line);
            if (options.ignore?.hasMatch(line) != true) {
              lastOutput = DateTime.now();
            }
          }),
    );
  }

  var stalled = false;
  final exit = Completer<int>();
  unawaited(
    process.exitCode.then((code) {
      if (!exit.isCompleted) exit.complete(code);
    }),
  );
  final timer = Timer.periodic(tick, (timer) {
    if (exit.isCompleted || stalled) return;
    if (DateTime.now().difference(lastOutput) > options.idle) {
      stalled = true;
      timer.cancel();
      exit.complete(-1);
    }
  });
  final code = await exit.future;
  timer.cancel();
  if (!stalled) {
    await Future.wait(done);
    return code;
  }

  err.writeln(
    '::warning::watch: no output for ${options.idle.inSeconds} s: '
    '${options.command.join(' ')}',
  );
  if (options.onStall case final onStall?) {
    err.writeln('watch: running --on-stall');
    final diag = await Process.start(
      Platform.isWindows ? 'cmd' : 'bash',
      Platform.isWindows ? ['/c', onStall] : ['-c', onStall],
      mode: ProcessStartMode.inheritStdio,
    );
    await diag.exitCode;
  }
  await killTree(process.pid);
  // The pipes close when the last process of the tree ends.
  await Future.wait(
    done,
  ).timeout(const Duration(seconds: 10), onTimeout: () => []);
  return stallExitCode;
}

/// Kills [pid] and every process that it started.
Future<void> killTree(int pid) async {
  if (Platform.isWindows) {
    await Process.run('taskkill', ['/T', '/F', '/PID', '$pid']);
    return;
  }
  final children = await Process.run('pgrep', ['-P', '$pid']);
  for (final child in LineSplitter.split('${children.stdout}')) {
    final id = int.tryParse(child.trim());
    if (id != null) await killTree(id);
  }
  Process.killPid(pid, ProcessSignal.sigkill);
}
