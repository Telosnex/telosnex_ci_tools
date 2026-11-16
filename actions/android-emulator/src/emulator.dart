// The emulator command line, and the parsing of its debugger and adb logs.

/// The GDB words before the emulator. GDB runs the emulator from the start:
/// a crash then gives frames with no ptrace attach and no core dump.
const kDebuggerArguments = [
  'gdb',
  '--batch',
  '--return-child-result',
  '-iex', 'set auto-load off',
  '-ex', 'set pagination off',
  '-ex', 'set confirm off',
  '-ex', 'set disable-randomization off',
  // No argument values and no locals in a frame (I6).
  '-ex', 'set print frame-arguments none',
  '-ex', 'set print entry-values no',
  '-ex', 'set print thread-events off',
  // QEMU uses these signals to wake vCPU threads, not to report a crash.
  '-ex', 'handle SIGUSR1 SIGUSR2 SIGALRM nostop noprint pass',
  '-ex', 'handle SIGPIPE nostop noprint pass',
  '-ex', 'run',
  '-ex', 'bt 40',
  '-ex', 'thread apply all bt 20',
  '--args',
];

/// The command that starts AVD [avd] of the SDK in [sdk].
List<String> emulatorCommand(
  String sdk,
  String avd, {
  required String gpu,
  List<String> extra = const [],
  bool adbTrace = false,
  bool debugger = true,
}) => [
  if (debugger) ...kDebuggerArguments,
  '$sdk/emulator/emulator',
  '-avd',
  avd,
  '-no-window',
  '-no-audio',
  '-no-boot-anim',
  '-no-snapshot',
  '-gpu',
  gpu,
  '-accel',
  'on',
  if (adbTrace) ...['-debug', 'adb,adbserver,adbclient'],
  ...extra,
];

/// Splits the emulator-args input on whitespace.
List<String> splitArguments(String text) =>
    text.trim().isEmpty ? const [] : text.trim().split(RegExp(r'\s+'));

/// A device serial that the tool may use: the emulator's own serial, or
/// guest adbd over TCP through the emulator redirect.
bool isDeviceSerial(String id) =>
    RegExp(r'^(?:emulator-\d+|127\.0\.0\.1:\d+)$').hasMatch(id);

/// The host adb server logs this when its connection to a device drops. With
/// [serial], only that device counts: over TCP, a drop of the unused
/// emulator serial does not affect the tests.
bool isAdbDisconnect(String line, {String? serial}) => serial == null
    ? RegExp(
        r'(?:\bemulator-\d+|\b127\.0\.0\.1:\d+): connection terminated\b',
      ).hasMatch(line)
    : line.contains('$serial: connection terminated');

/// Keeps only the signal, thread numbers and frame symbols of GDB output.
/// Never the command line, thread names, argument values, locals, source
/// lines or debugger warnings (I6).
String summarizeBacktrace(Iterable<String> lines) {
  final out = StringBuffer();
  final terminated = RegExp(r'^Program terminated with signal (SIG[A-Z0-9]+),');
  final received = RegExp(r'\breceived signal (SIG[A-Z0-9]+),');
  final thread = RegExp(r'^Thread ([0-9]+) \(');
  final current = RegExp(r'^\[Current thread is ([0-9]+) ');
  final frame = RegExp(r'^#([0-9]+)\s+(?:(0x[0-9a-fA-F]+) in )?(.+?) \(');
  final symbol = RegExp(r'^[a-zA-Z0-9_?:~<>.,*& +\[\]/()-]{1,500}$');
  final location = RegExp(r'\) (from|at) ([^\s]+)$');
  final fileName = RegExp(r'^[a-zA-Z0-9_.+:-]{1,180}$');
  var count = 0;
  for (final line in lines) {
    if (count >= 500) break;
    final signal = terminated.firstMatch(line) ?? received.firstMatch(line);
    final threadMatch = thread.firstMatch(line);
    final currentMatch = current.firstMatch(line);
    final frameMatch = frame.firstMatch(line);
    if (signal != null) {
      out.writeln('Signal: ${signal[1]}');
    } else if (currentMatch != null) {
      out.writeln('Crashing thread: ${currentMatch[1]}');
    } else if (threadMatch != null) {
      out.writeln('Thread ${threadMatch[1]}:');
    } else if (frameMatch != null) {
      final name = frameMatch[3]!;
      // A symbol with a quoted string or a control character is dropped.
      if (!symbol.hasMatch(name)) continue;
      out.write('#${frameMatch[1]} ${frameMatch[2] ?? ''} $name');
      final where = location.firstMatch(line);
      if (where != null) {
        final base = where[2]!.split('/').last;
        if (fileName.hasMatch(base)) out.write(' ${where[1]} $base');
      }
      out.writeln();
    } else {
      continue;
    }
    count++;
  }
  return out.toString();
}
