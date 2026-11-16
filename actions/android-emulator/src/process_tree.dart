import 'dart:io';

/// Sends [signal] to [pid] and all its descendants, children first.
Future<void> stopProcessTree(int pid, ProcessSignal signal) async {
  try {
    final children = await Process.run('pgrep', ['-P', '$pid']);
    if (children.exitCode == 0) {
      for (final line in (children.stdout as String).split('\n')) {
        final child = int.tryParse(line.trim());
        if (child != null) await stopProcessTree(child, signal);
      }
    }
  } on ProcessException {
    // Linux runners have pgrep. Without it, still stop the parent.
  }
  Process.killPid(pid, signal);
}

/// Whether [pid] is a running process that is not a zombie.
Future<bool> processAlive(int pid) async {
  if (pid <= 0) return false;
  final stat = File('/proc/$pid/stat');
  if (stat.existsSync()) {
    try {
      // The state follows the name in parentheses, which can have spaces.
      final text = stat.readAsStringSync();
      return text.substring(text.lastIndexOf(')') + 2).split(' ').first != 'Z';
    } on FileSystemException {
      return false;
    }
  }
  // Not Linux (local tests): kill -0 checks the process without a signal.
  final result = await Process.run('kill', ['-0', '$pid']);
  return result.exitCode == 0;
}
