import 'dart:io';

import 'console_protocol.dart';

/// The driver's side of the console: applies the results of
/// [pollConsoleScript] to a log file, in order, without gaps or repeats.
final class ConsoleTail {
  /// Starts [file] empty.
  ConsoleTail(this.file) {
    file
      ..createSync(recursive: true)
      ..writeAsStringSync('');
  }

  final File file;

  /// The number of the first line not read yet.
  int next = 0;

  /// Null before the first answer; false if the page has no capture.
  bool? installed;

  /// The running test and the newest line, from the last answer.
  String test = '';
  String last = '';

  /// The lines the page ever logged.
  int total = 0;

  /// Applies one answer. Returns whether more lines are waiting: the page
  /// returns at most [maxPollLines] at a time.
  bool apply(Map<String, Object?> answer) {
    installed = answer['installed'] == true;
    if (installed != true) return false;
    test = answer['test'] as String? ?? '';
    last = answer['last'] as String? ?? '';
    total = answer['total'] as int? ?? total;
    final lost = answer['lost'] as int? ?? 0;
    final added = (answer['added'] as List? ?? const []).cast<String>();
    final text = StringBuffer();
    if (lost > 0) {
      text.writeln(
        '[telosnex_web_test: the page dropped $lost console lines before '
        'they were read]',
      );
    }
    for (final line in added) {
      text.writeln(line);
    }
    if (text.isNotEmpty) {
      file.writeAsStringSync(text.toString(), mode: FileMode.append);
    }
    next = answer['next'] as int? ?? next + added.length;
    return next < total;
  }
}
