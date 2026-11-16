// A fake Android SDK, adb and emulator for the tests of android-emulator.
import 'dart:io';

import '../../actions/android-emulator/src/host.dart';

const _sdkmanager = r'''#!/bin/bash
echo "sdkmanager $*" >> "$FAKE/calls"
for arg in "$@"; do
  case "$arg" in
    system-images\;*)
      n=$(cat "$FAKE/image-failures" 2>/dev/null || echo 0)
      if [ "$n" -gt 0 ]; then echo $((n - 1)) > "$FAKE/image-failures"; exit 1; fi
      dir="$ANDROID_HOME/${arg//;//}"
      mkdir -p "$dir" && touch "$dir/system.img" ;;
  esac
done
cat > /dev/null
''';

const _avdmanager = r'''#!/bin/bash
echo "avdmanager $*" >> "$FAKE/calls"
while [ $# -gt 0 ]; do
  [ "$1" = -n ] && name=$2
  shift
done
mkdir -p "$ANDROID_AVD_HOME/$name.avd"
echo "avd.ini.encoding=UTF-8" > "$ANDROID_AVD_HOME/$name.avd/config.ini"
''';

const _emulator = r'''#!/bin/bash
if [ "$1" = -accel-check ]; then echo "KVM (version 12) is installed and usable."; exit 0; fi
echo "emulator $*" >> "$FAKE/calls"
mkdir -p "$FAKE/emulators"
echo $$ > "$FAKE/emulators/$$"
while [ $# -gt 0 ]; do [ "$1" = -port ] && echo $$ > "$FAKE/port-$2"; shift; done
echo "INFO | Boot completed"
exec sleep 1000
''';

const _adb = r'''#!/bin/bash
serial=""
if [ "$1" = -s ]; then serial=$2; shift 2; fi
case "$1" in
  kill-server) exit 0 ;;
  start-server)
    echo "$ANDROID_ADB_LOG_PATH" > "$FAKE/adb-log-path"
    echo "I adb : started" >> "$ANDROID_ADB_LOG_PATH" ;;
  get-state)
    case "$serial" in
      emulator-*)
        pid=$(cat "$FAKE/port-${serial#emulator-}" 2>/dev/null)
        if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
          echo "error: device '$serial' not found" >&2; exit 1
        fi ;;
    esac
    cat "$FAKE/state" 2>/dev/null || echo device ;;
  wait-for-device) exit 0 ;;
  connect|disconnect) exit 0 ;;
  devices) printf 'List of devices attached\n%s device\n' "$serial" ;;
  emu) exit 0 ;;
  logcat)
    if [ "$2" = -d ]; then echo "11-16 12:00:00.000 dump line"; exit 0; fi
    echo "logcat $*" >> "$FAKE/calls"
    echo "11-16 12:00:01.000  1  1 I fake: logcat line"
    exec sleep 1000 ;;
  shell)
    shift
    case "$*" in
      "getprop ro.product.cpu.abi") echo x86_64 ;;
      getprop*) echo 1 ;;
      "pidof system_server") echo 321 ;;
      *) echo "shell $*" ;;
    esac ;;
esac
exit 0
''';

const _java = r'''#!/bin/bash
echo 'openjdk version "17.0.12" 2024-07-16' >&2
''';

const _logger = r'''#!/bin/bash
echo "$(basename "$0") $*" >> "$FAKE/calls"
''';

/// A temporary fake SDK. [environment] runs the tool against it.
final class FakeAndroid {
  FakeAndroid() : root = Directory.systemTemp.createTempSync('fake-android-') {
    void script(String path, String text) {
      final file = File('${root.path}/$path')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(text);
      Process.runSync('chmod', ['+x', file.path]);
    }

    script('sdk/cmdline-tools/latest/bin/sdkmanager', _sdkmanager);
    script('sdk/cmdline-tools/latest/bin/avdmanager', _avdmanager);
    script('sdk/emulator/emulator', _emulator);
    script('sdk/platform-tools/adb', _adb);
    script('bin/java', _java);
    for (final name in ['setfacl', 'sudo', 'getfacl']) {
      script('bin/$name', _logger);
    }
    session.createSync();
  }

  final Directory root;
  Directory get fake => root;
  Directory get session => Directory('${root.path}/session');
  Directory get run => Directory('${root.path}/run');
  File get calls => File('${root.path}/calls');
  String get tool =>
      File('actions/android-emulator/android.dart').absolute.path;

  Map<String, String> get environment => {
    'PATH': '${root.path}/bin:${Platform.environment['PATH']}',
    'HOME': Platform.environment['HOME'] ?? root.path,
    'ANDROID_HOME': '${root.path}/sdk',
    'FAKE': root.path,
    'TELOSNEX_ANDROID_TOOL_TEST': '1',
    'TELOSNEX_ANDROID_TOOL_TEST_STARTUP_MS': '1500',
    'GITHUB_ENV': '${root.path}/github-env',
    'GITHUB_PATH': '${root.path}/github-path',
  };

  Host host([Map<String, String> extra = const {}]) =>
      Host.fromEnvironment({...environment, ...extra});

  /// Sets what `adb get-state` answers.
  set state(String value) =>
      File('${root.path}/state').writeAsStringSync('$value\n');

  /// The fake emulators that still run.
  Future<List<int>> aliveEmulators() async {
    final directory = Directory('${root.path}/emulators');
    if (!directory.existsSync()) return [];
    final alive = <int>[];
    for (final file in directory.listSync().whereType<File>()) {
      final pid = int.parse(file.uri.pathSegments.last);
      if ((await Process.run('kill', ['-0', '$pid'])).exitCode == 0) {
        alive.add(pid);
      }
    }
    return alive;
  }

  Future<void> dispose() async {
    for (final pid in await aliveEmulators()) {
      Process.killPid(pid, ProcessSignal.sigkill);
    }
    await Process.run('pkill', ['-f', root.path]);
    root.deleteSync(recursive: true);
  }
}
