@TestOn('mac-os || linux')
library;

import 'dart:io';

import 'package:test/test.dart';

import '../actions/watch/watch.dart';

Future<(int, String)> _watch(
  List<String> command, {
  int idle = 1,
  String? ignore,
  String? onStall,
}) async {
  final dir = Directory.systemTemp.createTempSync('watch');
  addTearDown(() => dir.deleteSync(recursive: true));
  final out = File('${dir.path}/out').openWrite();
  final code = await watch(
    WatchOptions(
      idle: Duration(seconds: idle),
      command: command,
      ignore: ignore == null ? null : RegExp(ignore),
      onStall: onStall,
    ),
    out: out,
    err: out,
    tick: const Duration(milliseconds: 100),
  );
  await out.close();
  return (code, File('${dir.path}/out').readAsStringSync());
}

void main() {
  test('passes on the exit code and the output', () async {
    final (code, out) = await _watch(['bash', '-c', 'echo hello; exit 3']);
    expect(code, 3);
    expect(out, contains('hello'));
  });

  test('output keeps a slow command alive', () async {
    final (code, _) = await _watch([
      'bash',
      '-c',
      r'for i in 1 2 3 4; do echo $i; sleep 0.5; done',
    ]);
    expect(code, 0);
  });

  test(
    'a stall runs --on-stall and kills the command and its children',
    () async {
      final marker = File(
        '${Directory.systemTemp.path}/watch_child_${DateTime.now().microsecondsSinceEpoch}',
      );
      addTearDown(() {
        if (marker.existsSync()) marker.deleteSync();
      });
      final clock = Stopwatch()..start();
      final (code, out) = await _watch([
        'bash',
        '-c',
        'echo start; (sleep 3; touch ${marker.path}) & sleep 30',
      ], onStall: 'echo saving diagnostics');
      expect(code, stallExitCode);
      expect(clock.elapsed, lessThan(const Duration(seconds: 10)));
      expect(out, contains('no output for 1 s'));
      await Future<void>.delayed(const Duration(seconds: 4));
      expect(marker.existsSync(), isFalse, reason: 'The child kept running.');
    },
  );

  test('ignored lines do not count as output', () async {
    final (code, _) = await _watch([
      'bash',
      '-c',
      r'for i in 1 2 3 4 5 6; do echo "[ +1 ms] $i"; sleep 0.5; done',
    ], ignore: r'^\[ *\+');
    expect(code, stallExitCode);
  });

  group('WatchOptions.parse', () {
    test('every option', () {
      final o = WatchOptions.parse([
        '--idle', '480', '--ignore', 'x', '--on-stall', 'y', '--', 'a', 'b', //
      ]);
      expect(o.idle, const Duration(minutes: 8));
      expect(o.ignore?.pattern, 'x');
      expect(o.onStall, 'y');
      expect(o.command, ['a', 'b']);
    });

    test('empty --ignore and --on-stall are unset', () {
      final o = WatchOptions.parse([
        '--idle',
        '1',
        '--ignore',
        '',
        '--on-stall',
        '',
        '--',
        'a',
      ]);
      expect(o.ignore, isNull);
      expect(o.onStall, isNull);
    });

    for (final args in [
      ['--idle', '1'],
      ['--', 'a'],
      ['--idle', 'x', '--', 'a'],
      ['--nope', '--', 'a'],
    ]) {
      test('rejects $args', () {
        expect(() => WatchOptions.parse(args), throwsFormatException);
      });
    }
  });
}
