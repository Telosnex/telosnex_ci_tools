// Runs `dart run <package>:build` for one target. actions/kiln-build
// runs this file with the environment variables of its action.yml.
//
// This file uses only dart:io and dart:convert: the action runs it without a
// pub get. test/kiln_build_test.dart imports it.
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  final env = Platform.environment;
  final package = _require(env, 'PACKAGE');
  final target = _require(env, 'TARGET');
  final out = _require(env, 'OUT');
  final runner = _require(env, 'RUNNER');

  final List<String> buildArgs;
  final List<String> extras;
  try {
    buildArgs = argsFor(env['BUILD_ARGS'] ?? '', target, env);
    extras = extrasFor(env['TOOLCHAIN_EXTRA'] ?? '', target, env);
  } on FormatException catch (e) {
    stdout.writeln('::error::${e.message}');
    exit(1);
  }

  final toolchain = [
    ...await describeToolchain(target, env),
    ...extras,
  ].join(', ');
  stdout.writeln('Toolchain: $toolchain');
  final outputFile = env['GITHUB_OUTPUT'];
  if (outputFile != null) {
    File(
      outputFile,
    ).writeAsStringSync('toolchain=$toolchain\n', mode: FileMode.append);
  }

  final targetOut = '$out/out/$target';
  final args = [
    'run',
    '$package:build',
    '--target',
    target,
    '--out',
    targetOut,
    '--runner',
    runner,
    '--toolchain',
    toolchain,
    ...buildArgs,
  ];
  stdout.writeln('dart ${args.join(' ')}');
  final process = await Process.start(
    Platform.resolvedExecutable,
    args,
    mode: ProcessStartMode.inheritStdio,
  );
  final code = await process.exitCode;
  if (code != 0) exit(code);
  stdout.writeln(File('$targetOut/target.json').readAsStringSync());
}

String _require(Map<String, String> env, String name) {
  final value = env[name];
  if (value == null || value.isEmpty) {
    stdout.writeln('::error::The environment variable $name is not set.');
    exit(1);
  }
  return value;
}

/// The compiler of the target platform, then CMake if it is on PATH.
Future<List<String>> describeToolchain(
  String target,
  Map<String, String> env,
) async {
  final parts = <String>[];
  if (target.startsWith('android-')) {
    parts.add('Android NDK ${env['NDK_VERSION'] ?? 'unknown'}');
  } else if (target.startsWith('windows-')) {
    final vs = await _firstLine(
      r'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe',
      [
        '-latest',
        '-products',
        '*',
        '-property',
        'catalog_productDisplayVersion',
      ],
    );
    parts.add('Visual Studio ${vs ?? 'unknown'}');
  } else if (target.startsWith('macos-') || target.startsWith('ios-')) {
    parts.add(await _firstLine('xcodebuild', ['-version']) ?? 'Xcode unknown');
  } else if (target.startsWith('linux-')) {
    parts.add(await _firstLine('gcc', ['--version']) ?? 'gcc unknown');
  }
  final cmake = await _firstLine('cmake', ['--version']);
  if (cmake != null) parts.add(cmake);
  return parts;
}

Future<String?> _firstLine(String executable, List<String> args) async {
  try {
    final result = await Process.run(executable, args);
    if (result.exitCode != 0) return null;
    for (final line in '${result.stdout}\n${result.stderr}'.split('\n')) {
      if (line.trim().isNotEmpty) return line.trim();
    }
  } on ProcessException {
    // Not on PATH.
  }
  return null;
}

/// The arguments of every entry in [json] whose pattern matches [target], in
/// the order of the JSON object.
List<String> argsFor(String json, String target, Map<String, String> env) => [
  for (final value in _matching(json, target))
    if (value is List)
      for (final arg in value) expand('$arg', env)
    else
      throw FormatException('build-args: "$value" is not a list.'),
];

/// The texts of every entry in [json] whose pattern matches [target].
List<String> extrasFor(String json, String target, Map<String, String> env) => [
  for (final value in _matching(json, target))
    if (value is String)
      expand(value, env)
    else
      throw FormatException('toolchain-extra: "$value" is not a string.'),
];

Iterable<Object?> _matching(String json, String target) {
  if (json.trim().isEmpty) return const [];
  final decoded = jsonDecode(json);
  if (decoded is! Map<String, Object?>) {
    throw FormatException('"$json" is not a JSON object.');
  }
  return [
    for (final MapEntry(:key, :value) in decoded.entries)
      if (matchesTarget(key, target)) value,
  ];
}

/// `*` matches any text, including an empty text.
bool matchesTarget(String pattern, String target) => RegExp(
  '^${pattern.split('*').map(RegExp.escape).join('.*')}\$',
).hasMatch(target);

/// Replaces ${NAME} with the environment variable NAME.
String expand(String text, Map<String, String> env) =>
    text.replaceAllMapped(RegExp(r'\$\{(\w+)\}'), (m) {
      final value = env[m[1]!];
      if (value == null) {
        throw FormatException('"$text": \$${m[1]} is not set.');
      }
      return value;
    });
