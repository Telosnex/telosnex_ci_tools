# android-emulator

Boots an x86_64 Android emulator with KVM on an x64 Linux runner. The action
calls `android.dart`. A caller can also run `android.dart` itself, for a
supervised test run with one retry.

`android.dart` imports only the Dart SDK. Run it with `dart <path>`, not
`dart run`: it needs no `pub get`. Flutter or Dart must be on `PATH`.

## Commands

| Command | What it does |
|---|---|
| `prepare --session DIR [inputs]` | Install Java 17 if the runner has none, GDB and `acl` if missing, the emulator and the system image. Check KVM, create the AVD. No boot. |
| `boot --session DIR [--fresh]` | Boot the AVD and wait until it is ready. `--fresh` stops the emulator of this session first. Writes `serial=` to `GITHUB_OUTPUT`. |
| `run --session DIR --run-dir DIR [--startup-protocol flutter-machine] [--timeout-minutes N] -- COMMAND ARG...` | Boot, run the command under supervision, retry per I7, stop. |
| `stop --session DIR` | Stop only the processes that this session started. Safe to run twice. |
| `diagnostics --session DIR --output-dir DIR --phase NAME [--after-failure]` | Append bounded device diagnostics to `OUTPUT/device-diagnostics.txt`. With `--after-failure`, also the guest log buffer to `OUTPUT/logcat-dump.txt`. |

The inputs of `prepare` are the inputs of the action, as options:
`--api-level`, `--target`, `--device`, `--gpu`, `--emulator-args`,
`--boot-timeout-minutes`, `--gdb`, `--adb-trace`, `--cores`,
`--adb-transport`, `--ram-mb`. An empty value is no value.

A new emulator is a new process with `-no-snapshot`. It does not wipe user
data.

Ready means: `sys.boot_completed` and `dev.bootcomplete` are 1, the package
manager answers, and `system_server` keeps its pid for 60 seconds. Then the
tool keeps the screen on, sets the animation scales to 0, and unlocks.

## Files

`DIR/session.json`, written atomically by `boot`:

```json
{
  "schemaVersion": 1,
  "consoleSerial": "emulator-5554",
  "serial": "127.0.0.1:5600",
  "abi": "x86_64"
}
```

The session directory also has `emulator.log` (the emulator and GDB),
`logcat.txt`, `adb-server.log` (the log of the host adb server),
`host-load.txt`, `host-diagnostics.txt`, and, after an unasked stop,
`emulator-exit.json`. Other files in it are private.

`run` writes `RUN_DIR/result.json` and one directory for each attempt:
`RUN_DIR/attempts/1/`, `RUN_DIR/attempts/2/`. An attempt directory has
`command.stdout`, `command.stderr`, the session files of that attempt, and
`backtrace.txt` when GDB printed frames. `backtrace.txt` has only the
signal, thread numbers and symbols (I6).

`result.json` has only fixed fields. It never has environment values, VM
service URIs, command lines or log lines:

```json
{
  "schemaVersion": 1,
  "exitCode": 0,
  "elapsedMs": 1260000,
  "attempts": [
    {
      "attempt": 1,
      "exitCode": 75,
      "elapsedMs": 180000,
      "markers": ["android-adb-disconnect"],
      "testStarted": false,
      "emulatorStopped": false,
      "evidence": ["attempts/1/command.stdout", "attempts/1/logcat.txt"]
    }
  ]
}
```

The command of `run` gets these environment variables:

| Variable | Value |
|---|---|
| `ANDROID_SERIAL` | The serial for tests. |
| `ANDROID_CONSOLE_SERIAL` | The emulator console serial. |
| `ANDROID_ABI` | The ABI of the device. |
| `ANDROID_ATTEMPT` | `1` or `2`. |
| `ANDROID_ATTEMPT_DIR` | The directory of this attempt. |

## Markers and exit codes

The prefix before `:` is the contract. The text after it is not. `run`
prints the marker lines on stderr, and puts their labels in `result.json`.

| Marker or exit | Label | Meaning | Retry |
|---|---|---|---|
| `ANDROID_ADB_DISCONNECT:` | `android-adb-disconnect` | The adb server log shows that the selected serial was lost during the command. | Only per I7 |
| `ANDROID_EMULATOR_EXIT:` | `android-emulator-exit` | The emulator stopped when no stop was asked, also with exit 0. | Never |
| `ANDROID_DEVICE_OFFLINE:` | `android-device-offline` | Three probes in a row show a state that is not `device`. | Never |
| `ANDROID_TEST_STARTUP_TIMEOUT:` | `android-test-startup-timeout` | The VM service started, but no test started in 2 minutes. | Never |
| Exit 0 | | The command passed and no marker occurred. | |
| Other nonzero exit of the command | | The test or build result, unchanged. | Never |
| Exit 2 | | Wrong configuration or a launcher error. | Never |
| Exit 124 | | The attempt took too long. | Never |
| Exit 125 | | An infrastructure failure, also a retry that was not allowed or that also failed. | Never |

Inside `run`, exit 75 means "adb lost before the first test". `run` never
returns 75. A command that exits 75 by itself gets 125: only the watcher
makes an attempt retryable.

I7: `run` makes at most 2 attempts. It retries only when all are true: adb
lost the selected serial during the command, no test started, the emulator
did not stop, and attempt 1 took less than 900 seconds. It retries only with
`--startup-protocol flutter-machine`, because it needs the machine JSON to
know whether a test started.

## Switches

An action input wins, then the environment variable, then the default:

| Input | Variable | Default |
|---|---|---|
| `gdb` | `TELOSNEX_ANDROID_GDB` (only `false` turns it off) | `true` |
| `adb-trace` | `TELOSNEX_ANDROID_ADB_TRACE` (only `true` turns it on) | `false` |
| `cores` | `TELOSNEX_ANDROID_EMULATOR_CORES` (`default`, or 1 to 16) | `4` |
| `adb-transport` | (`emulator` or `tcp`) | `emulator` |
| `prepare-only` | | `false` |
| `ram-mb` | (`default` keeps the AVD value) | `4096` |

With `tcp`, tests use guest adbd on `127.0.0.1:5600` through an emulator
redirect. Over virtio-vsock, guest adbd can get ENOMEM under memory pressure
and close the connection. If TCP does not connect, the serial stays the
console serial.
