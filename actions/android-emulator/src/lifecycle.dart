// prepare, boot, stop: the emulator of one session directory.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'config.dart';
import 'contract.dart';
import 'host.dart';
import 'process_tree.dart';

/// The host port of guest adbd with adb-transport tcp.
const kTcpPort = 5600;

final class LifecycleException implements Exception {
  const LifecycleException(this.message);
  final String message;
  @override
  String toString() => message;
}

void _log(String message) => stderr.writeln(message);

/// The inputs of `prepare`, from the action.
final class PrepareInputs {
  const PrepareInputs({
    this.apiLevel = '35',
    this.target = 'google_apis',
    this.device = 'pixel_6',
    this.gpu = 'swiftshader_indirect',
    this.emulatorArguments = const [],
    this.bootTimeout = const Duration(minutes: 15),
    this.avd = 'ci',
    this.switches = const Switches(),
  });

  final String apiLevel;
  final String target;
  final String device;
  final String gpu;
  final List<String> emulatorArguments;
  final Duration bootTimeout;
  final String avd;
  final Switches switches;
}

/// Installs what the emulator needs and creates the AVD. Starts no emulator.
Future<void> prepare(Host host, Directory session, PrepareInputs inputs) async {
  if (host.checkPlatform &&
      (!Platform.isLinux || host.environment['RUNNER_ARCH'] != 'X64')) {
    throw const LifecycleException(
      'android-emulator needs an x64 Linux runner with KVM (ubuntu-24.04).',
    );
  }
  if (!File(host.kvm).existsSync() && !Link(host.kvm).existsSync()) {
    throw LifecycleException('This runner has no ${host.kvm}.');
  }
  session.createSync(recursive: true);
  await _installHostPackages(host, gdb: inputs.switches.gdb);
  final java = await _java17(host);
  final sdk = host.sdk;
  final sdkmanager = '$sdk/cmdline-tools/latest/bin/sdkmanager';
  final javaEnvironment = {'JAVA_HOME': ?java};
  // yes(1) would end with SIGPIPE; a fixed answer list does not.
  await host.run(
    sdkmanager,
    ['--licenses'],
    input: 'y\n' * 64,
    timeout: const Duration(minutes: 5),
    extraEnvironment: javaEnvironment,
  );
  final image =
      'system-images;android-${inputs.apiLevel};${inputs.target};x86_64';
  final imageDirectory = Directory('$sdk/${image.replaceAll(';', '/')}');
  // Google's mirror sometimes serves a truncated image ("Error on ZipFile
  // unknown archive"; zxing_dart, 2026-10-30). Judge by the installed image,
  // not by the exit code of sdkmanager.
  for (var attempt = 1; ; attempt++) {
    await host.run(
      sdkmanager,
      ['platform-tools', 'emulator', image],
      timeout: const Duration(minutes: 20),
      extraEnvironment: javaEnvironment,
    );
    if (File('${imageDirectory.path}/system.img').existsSync()) break;
    if (attempt == 3) throw LifecycleException('$image did not install.');
    stdout.writeln(
      '::warning::$image did not install (try $attempt); trying again.',
    );
    if (imageDirectory.existsSync()) imageDirectory.deleteSync(recursive: true);
    await Future<void>.delayed(host.installPause);
  }
  host.githubFile('GITHUB_PATH', '$sdk/platform-tools');
  await _openKvm(host);
  final accel = await host.run('$sdk/emulator/emulator', ['-accel-check']);
  if (!accel.ok) {
    throw const LifecycleException('The emulator cannot use KVM.');
  }
  final avdHome = Directory('${session.path}/avd')..createSync();
  final created = await host.run(
    '$sdk/cmdline-tools/latest/bin/avdmanager',
    [
      'create',
      'avd',
      '--force',
      '-n',
      inputs.avd,
      '-k',
      image,
      '-d',
      inputs.device,
    ],
    input: 'no\n',
    timeout: const Duration(minutes: 2),
    extraEnvironment: {...javaEnvironment, 'ANDROID_AVD_HOME': avdHome.path},
  );
  final ini = File('${avdHome.path}/${inputs.avd}.avd/config.ini');
  if (!created.ok || !ini.existsSync()) {
    throw const LifecycleException('avdmanager did not create the AVD.');
  }
  final switches = inputs.switches;
  ini.writeAsStringSync(
    [
      '',
      if (switches.ramMb != null) 'hw.ramSize=${switches.ramMb}',
      'disk.dataPartition.size=8G',
      if (switches.cores != null) 'hw.cpu.ncore=${switches.cores}',
      'hw.gpu.enabled=yes',
      'hw.gpu.mode=${inputs.gpu}',
      '',
    ].join('\n'),
    mode: FileMode.append,
  );
  host.githubFile('GITHUB_ENV', 'ANDROID_AVD_HOME=${avdHome.path}');
  EmulatorConfig(
    avd: inputs.avd,
    avdHome: avdHome.path,
    image: image,
    gpu: inputs.gpu,
    extraArguments: inputs.emulatorArguments,
    bootTimeout: inputs.bootTimeout,
    switches: switches,
  ).write(session);
  stdout.writeln('Prepared AVD ${inputs.avd} ($image).');
}

Future<void> _installHostPackages(Host host, {required bool gdb}) async {
  final missing = [
    if (gdb && !(await host.run('gdb', ['--version'])).ok) 'gdb',
    if (!(await host.run('setfacl', ['--version'])).ok) 'acl',
  ];
  if (missing.isEmpty) return;
  _log('Installing ${missing.join(' ')}.');
  await host.run('sudo', [
    '-n',
    'apt-get',
    'update',
    '-qq',
  ], timeout: const Duration(minutes: 5));
  final install = await host.run('sudo', [
    '-n',
    'apt-get',
    'install',
    '-y',
    '-qq',
    '--no-install-recommends',
    ...missing,
  ], timeout: const Duration(minutes: 10));
  if (!install.ok) {
    throw LifecycleException('Could not install ${missing.join(' ')}.');
  }
}

/// Returns a JAVA_HOME for Java 17 or newer, or null to keep the current
/// one. Installs Java 17 when the runner has none.
Future<String?> _java17(Host host) async {
  final version = await host.run('java', ['-version']);
  final major = RegExp(
    r'version "(\d+)',
  ).firstMatch('${version.stdout}${version.stderr}');
  if (version.ok && major != null && int.parse(major[1]!) >= 17) return null;
  var home = host.environment['JAVA_HOME_17_X64'] ?? '';
  if (home.isEmpty) {
    _log('Installing Java 17.');
    await host.run('sudo', [
      '-n',
      'apt-get',
      'update',
      '-qq',
    ], timeout: const Duration(minutes: 5));
    final install = await host.run('sudo', [
      '-n',
      'apt-get',
      'install',
      '-y',
      '-qq',
      '--no-install-recommends',
      'openjdk-17-jdk-headless',
    ], timeout: const Duration(minutes: 10));
    home = '/usr/lib/jvm/java-17-openjdk-amd64';
    if (!install.ok || !Directory(home).existsSync()) {
      throw const LifecycleException('Could not install Java 17.');
    }
  }
  host.githubFile('GITHUB_ENV', 'JAVA_HOME=$home');
  host.githubFile('GITHUB_PATH', '$home/bin');
  return home;
}

/// Opens KVM to the job user. A device reset drops the ACL; the udev rule
/// keeps it open.
Future<void> _openKvm(Host host) async {
  if (!host.checkPlatform) return;
  final user = (await host.run('id', ['-un'])).line;
  await host.run('sudo', ['-n', 'setfacl', '-m', 'u:$user:rw', host.kvm]);
  await host.run('sudo', [
    '-n',
    'sh',
    '-c',
    'echo \'KERNEL=="kvm", GROUP="kvm", MODE="0666", OPTIONS+="static_node=kvm"\' '
        '> /etc/udev/rules.d/99-telosnex-kvm.rules && '
        'udevadm control --reload-rules && udevadm trigger --name-match=kvm',
  ]);
}

/// The processes of a session: the daemon that owns the emulator.
final class Owned {
  const Owned({required this.daemonPid, required this.port});

  factory Owned.fromJson(Map<String, Object?> json) =>
      Owned(daemonPid: json['daemonPid'] as int, port: json['port'] as int);

  static Owned? read(Directory session) => session.owned.existsSync()
      ? Owned.fromJson(readJson(session.owned))
      : null;

  final int daemonPid;

  /// The console port: the emulator serial is emulator-PORT.
  final int port;

  String get consoleSerial => 'emulator-$port';

  void write(Directory session) => writeAtomically(
    session.owned,
    '${jsonEncode({'daemonPid': daemonPid, 'port': port})}\n',
  );
}

Future<bool> _portFree(int port) async {
  try {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
    await socket.close();
    return true;
  } on SocketException {
    return false;
  }
}

/// The first even console port from 5554 whose ADB port is also free.
Future<int> _freePort() async {
  for (var port = 5554; port < 5682; port += 2) {
    if (await _portFree(port) && await _portFree(port + 1)) return port;
  }
  throw const LifecycleException('No free emulator port.');
}

/// Boots the AVD of [session] and waits until it is ready. With [fresh], it
/// stops the emulator of this session first. Without it, a running session
/// stays as it is.
Future<Session> boot(
  Host host,
  Directory session, {
  required String tool,
  bool fresh = false,
}) async {
  final config = EmulatorConfig.read(session);
  final current = Session.read(session);
  final owned = Owned.read(session);
  if (!fresh &&
      current != null &&
      owned != null &&
      await processAlive(owned.daemonPid)) {
    return current;
  }
  await stop(host, session);
  final started = DateTime.now();
  final deadline = started.add(config.bootTimeout);
  for (final file in [
    session.emulatorExit,
    session.stopRequested,
    Session.file(session),
  ]) {
    if (file.existsSync()) file.deleteSync();
  }
  await _openKvm(host);
  await _startAdbServer(host, session, trace: config.switches.adbTrace);
  final port = await _freePort();
  final daemon = await Process.start(
    Platform.resolvedExecutable,
    [tool, '_daemon', '--session', session.path, '--port', '$port'],
    environment: host.environment,
    includeParentEnvironment: false,
    mode: ProcessStartMode.detached,
  );
  Owned(daemonPid: daemon.pid, port: port).write(session);
  final console = 'emulator-$port';
  Future<void> check(String phase) async {
    if (session.emulatorExit.existsSync()) {
      throw LifecycleException(
        '${Marker.emulatorExit.line('the emulator stopped $phase')}.',
      );
    }
    if (!await processAlive(daemon.pid)) {
      throw LifecycleException('The emulator launcher stopped $phase.');
    }
    if (DateTime.now().isAfter(deadline)) {
      throw LifecycleException(
        'The emulator did not get ready in ${config.bootTimeout.inMinutes} '
        'minutes ($phase).',
      );
    }
  }

  while ((await host.device(console, ['get-state'])).line != 'device') {
    await check('before adb saw it');
    await Future<void>.delayed(host.poll);
  }
  await _waitReady(host, console, () => check('during boot'));
  final serial = config.switches.tcp ? await _useTcp(host, console) : console;
  // Keep the device awake and its animations off for tests.
  for (final command in [
    ['svc', 'power', 'stayon', 'true'],
    ['settings', 'put', 'system', 'screen_off_timeout', '2147483647'],
    for (final scale in [
      'window_animation_scale',
      'transition_animation_scale',
      'animator_duration_scale',
    ])
      ['settings', 'put', 'global', scale, '0'],
    ['input', 'keyevent', '82'],
  ]) {
    await host.device(serial, ['shell', ...command]);
  }
  final abi = await host.property(serial, 'ro.product.cpu.abi');
  final ready = Session(consoleSerial: console, serial: serial, abi: abi);
  ready.write(session);
  stdout.writeln(
    'Android emulator ready after '
    '${DateTime.now().difference(started).inSeconds} s ($abi).',
  );
  return ready;
}

/// Starts the host adb server with its log in the session. The log shows
/// why the host drops a device connection, which logcat cannot show.
Future<void> _startAdbServer(
  Host host,
  Directory session, {
  required bool trace,
}) async {
  await host.adbCommand(['kill-server']);
  final started = await host.run(
    host.adb,
    ['start-server'],
    extraEnvironment: {
      'ANDROID_ADB_LOG_PATH': session.adbServerLog.path,
      // Each client request and transport event, for a trace experiment.
      'ADB_TRACE': trace ? 'adb,sockets,transport,services' : '',
    },
  );
  if (!started.ok) {
    throw const LifecycleException('adb start-server failed.');
  }
}

/// Ready: boot completed, the package manager answers, and system_server
/// keeps its pid for [Host.settleChecks] checks in a row. On android-37.0
/// with swiftshader_indirect, surfaceflinger aborted about every 40 s and
/// each abort restarted system_server; an install then failed.
Future<void> _waitReady(
  Host host,
  String serial,
  Future<void> Function() check,
) async {
  var settled = 0;
  String? server;
  while (settled < host.settleChecks) {
    await check();
    await Future<void>.delayed(host.poll);
    final pid = (await host.device(serial, [
      'shell',
      'pidof',
      'system_server',
    ])).line;
    final good =
        await host.property(serial, 'sys.boot_completed') == '1' &&
        await host.property(serial, 'dev.bootcomplete') == '1' &&
        (await host.device(serial, ['shell', 'pm', 'path', 'android'])).ok &&
        pid.isNotEmpty &&
        (server == null || pid == server);
    if (good) {
      server = pid;
      settled++;
    } else {
      if (settled > 0) _log('Android restarted after boot; waiting again.');
      settled = 0;
      server = null;
    }
  }
}

/// Moves adb from virtio-vsock to TCP. Over vsock, the guest kernel (6.6)
/// needs a 128 KiB contiguous buffer for each adb packet. Under memory
/// pressure that fails, guest adbd gets ENOMEM and closes the connection,
/// which ends flutter test. Guest adbd also listens on tcp:5555. If TCP
/// never connects, the tests use the console serial.
Future<String> _useTcp(Host host, String console) async {
  const serial = '127.0.0.1:$kTcpPort';
  var answers = '';
  final redirect = await host.device(console, [
    'emu',
    'redir',
    'add',
    'tcp:$kTcpPort:5555',
  ]);
  var restarted = false;
  for (var attempt = 1; attempt <= host.tcpTries; attempt++) {
    final connect = await host.adbCommand(['connect', serial]);
    final state = await host.device(serial, ['get-state']);
    if (state.line == 'device') {
      _log('adb uses TCP ($serial), attempt $attempt.');
      return serial;
    }
    answers =
        'redir: ${_short(redirect)}; connect: ${_short(connect)}; '
        'state: ${_short(state)}';
    // A transport that stays offline is not replaced by a new connect.
    await host.adbCommand(['disconnect', serial]);
    if (!restarted && attempt >= 2) {
      // Guest adbd does not always listen on tcp:5555 after boot. tcpip
      // restarts it with that port; the console transport comes back.
      restarted = true;
      await host.device(console, ['tcpip', '5555']);
      await host.device(console, [
        'wait-for-device',
      ], timeout: const Duration(seconds: 60));
    }
    await Future<void>.delayed(host.tcpPause);
  }
  stdout.writeln(
    '::warning::adb over TCP did not connect; tests use $console. '
    'Last answers: $answers',
  );
  return console;
}

/// The first line of the output of adb, bounded, with no workflow command.
String _short(CommandResult result) {
  final text =
      (result.line.isEmpty
              ? const LineSplitter().convert(result.stderr).firstOrNull ?? ''
              : result.line)
          .replaceAll(RegExp(r'[^ -~]'), '?')
          .replaceAll('::', ': :');
  return '${result.exitCode} ${text.length > 120 ? text.substring(0, 120) : text}';
}

/// Stops only the processes that this session started. Safe to run twice.
Future<void> stop(Host host, Directory session) async {
  final owned = Owned.read(session);
  if (owned == null) return;
  session.stopRequested.writeAsStringSync('stop\n');
  final current = Session.read(session);
  if (current != null && current.serial != current.consoleSerial) {
    await host.adbCommand(['disconnect', current.serial]);
  }
  final emulator = int.tryParse(
    session.emulatorPid.existsSync()
        ? session.emulatorPid.readAsStringSync().trim()
        : '',
  );
  if (await processAlive(owned.daemonPid)) {
    // The daemon stops the emulator and writes no exit marker.
    Process.killPid(owned.daemonPid, ProcessSignal.sigterm);
    final until = DateTime.now().add(host.terminationGrace);
    while (await processAlive(owned.daemonPid) &&
        DateTime.now().isBefore(until)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (await processAlive(owned.daemonPid)) {
      await stopProcessTree(owned.daemonPid, ProcessSignal.sigkill);
    }
  }
  // A new emulator cannot use KVM while the old one still holds it.
  if (emulator != null) {
    final until = DateTime.now().add(const Duration(seconds: 30));
    while (await processAlive(emulator) && DateTime.now().isBefore(until)) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    if (await processAlive(emulator)) {
      await stopProcessTree(emulator, ProcessSignal.sigkill);
    }
  }
  // The session started this adb server, with its log in the session.
  await host.adbCommand(['kill-server']);
  for (final file in [
    session.owned,
    session.emulatorPid,
    Session.file(session),
  ]) {
    if (file.existsSync()) file.deleteSync();
  }
}
