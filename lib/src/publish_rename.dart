// Renames a repository's packages to their published names (ADR D1): the
// fork keeps upstream's names in git, and the publish workflow renames a
// throwaway checkout. See bin/publish_rename.dart.
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// Where a repository keeps its published names.
const publishNamesPath = 'tool/publish_names.yaml';

/// The branch the publish workflow commits each published renamed tree to.
/// pana reads a repository URL's branch as one segment of `[a-z0-9]+`.
const publishedBranch = 'published';

/// A package's published name and, for a package of another repository,
/// the version constraint its git or path dependency becomes.
final class PublishName {
  const PublishName(this.name, {this.version});
  final String name;
  final String? version;
}

/// tool/publish_names.yaml.
final class PublishNames {
  const PublishNames(
    this.names, {
    this.renameLines = const [],
    this.keepLines = const [],
    this.lines = const [],
  });

  /// Upstream name -> published name.
  final Map<String, PublishName> names;

  /// A string of published code (lib, bin, hook) that is only an old
  /// name: renamed when `path:text before it on its line` matches one of
  /// [renameLines] (`packageName: $`), kept when it matches one of
  /// [keepLines] (`MethodChannel\($`: the native side has the same name),
  /// else an error. The path is relative to the repository, with `/`.
  final List<RegExp> renameLines, keepLines;

  /// Lines of any Dart file where every old name (a whole word) is
  /// renamed, matched against `path:line`: tests that write a pubspec in a
  /// string, or look a package up by name.
  final List<RegExp> lines;
}

/// Reads tool/publish_names.yaml:
/// ```yaml
/// names:
///   upstream: published
///   other_repo_package: {name: published, version: ^1.2.3}
/// strings:          # a string that is only an old name, by
///   rename: [regex] # "path:text before it on its line": rename it
///   keep: [regex]   # or keep it
/// lines: [regex]    # "path:line": rename every old name on it
/// ```
PublishNames parsePublishNames(String text) {
  final doc = loadYaml(text);
  if (doc is! YamlMap || doc['names'] is! YamlMap) {
    throw const FormatException('Needs a "names:" map.');
  }
  List<RegExp> regexes(Object? list, String key) {
    if (list == null) return const [];
    if (list is! YamlList || list.any((e) => e is! String)) {
      throw FormatException('$key: a list of regular expressions.');
    }
    return [for (final e in list) RegExp(e as String)];
  }

  final strings = doc['strings'];
  final names = <String, PublishName>{};
  for (final MapEntry(:key, :value) in (doc['names'] as YamlMap).entries) {
    names[key as String] = switch (value) {
      final String name => PublishName(name),
      YamlMap() when value['name'] is String => PublishName(
        value['name'] as String,
        version: value['version'] as String?,
      ),
      _ => throw FormatException('$key: a name, or {name, version}.'),
    };
  }
  for (final MapEntry(:key, :value) in names.entries) {
    if (!RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(value.name)) {
      throw FormatException('$key: "${value.name}" is no package name.');
    }
  }
  return PublishNames(
    names,
    renameLines: regexes(
      strings is YamlMap ? strings['rename'] : null,
      'strings.rename',
    ),
    keepLines: regexes(
      strings is YamlMap ? strings['keep'] : null,
      'strings.keep',
    ),
    lines: regexes(doc['lines'], 'lines'),
  );
}

final class RenameReport {
  /// Files changed, relative to the repository.
  final changed = <String>{};

  /// Files renamed: from -> to, relative to the repository.
  final moved = <String, String>{};

  /// Lines of published code with a string that is only an old name, by
  /// what happened: renamed or kept (path:line: text).
  final renamedStrings = <String>[], keptStrings = <String>[];

  /// Problems that make the output wrong.
  final errors = <String>[];

  /// The renamed packages' directories, relative to the repository, by old
  /// name (after --move-directories, the new directories).
  final packageDirs = <String, String>{};
}

final _skipDirs = {'.git', '.dart_tool', 'build', 'node_modules', '.idea'};
const _nativeDirs = {'ios', 'macos', 'darwin', 'linux', 'windows'};

/// Renames the packages of the repository at [root] in place.
Future<RenameReport> renameRepository(
  String root,
  PublishNames config, {
  bool rekey = true,
  bool moveDirectories = false,
  String? repository,
  String? ref,
}) async {
  final names = config.names;
  final report = RenameReport();
  final files = _files(Directory(root)).toList();

  // Versions of the packages in this repository, for path dependencies.
  final versions = <String, String>{};
  final pubspecs = files.where((f) => p.basename(f.path) == 'pubspec.yaml');
  final packageDirs = <String, String>{}; // old name -> directory
  for (final f in pubspecs) {
    final doc = loadYaml(f.readAsStringSync());
    if (doc is! YamlMap) continue;
    final name = doc['name'], version = doc['version'];
    if (name is String && version is String) versions[name] = version;
    if (name is String && names.containsKey(name)) {
      packageDirs[name] = f.parent.path;
    }
  }

  void write(File f, String before, String after) {
    if (before == after) return;
    f.writeAsStringSync(after);
    report.changed.add(p.relative(f.path, from: root));
  }

  for (final f in files) {
    final rel = p.relative(f.path, from: root);
    final base = p.basename(f.path);
    final String text;
    try {
      text = f.readAsStringSync();
    } on FileSystemException {
      continue; // Not UTF-8: no names to rename.
    }
    if (base == 'pubspec.yaml') {
      write(
        f,
        text,
        renamePubspec(
          text,
          names,
          versions,
          published: !_inExample(rel),
          onError: (e) => report.errors.add('$rel: $e'),
        ),
      );
    } else if (base.endsWith('.dart')) {
      var out = renameDart(text, names);
      if (_isPublishedCode(f.path, packageDirs.values)) {
        out = _renameStrings(out, rel, config, report);
      }
      if (config.lines.isNotEmpty) out = _renameLines(out, rel, config);
      write(f, text, out);
    } else if (base == 'build.yaml') {
      write(f, text, renameBuildYaml(text, names));
    } else if (base.startsWith('analysis_options') && base.endsWith('.yaml')) {
      write(f, text, renameAnalysisOptions(text, names));
    }
  }

  for (final MapEntry(key: old, value: dir) in packageDirs.entries) {
    report.packageDirs[old] = p.relative(dir, from: root);
    final renamed = names[old]!.name;
    for (final platform in _nativeDirs) {
      final pd = Directory(p.join(dir, platform));
      if (pd.existsSync()) {
        _renameNative(root, pd, old, renamed, report);
      }
    }
  }

  if (repository != null) {
    for (final dir in packageDirs.values) {
      final f = File(p.join(dir, 'pubspec.yaml'));
      final text = f.readAsStringSync();
      final rel = p.posix.joinAll(p.split(p.relative(dir, from: root)));
      final out = setRepository(
        text,
        repository,
        ref: ref ?? 'main',
        path: rel == '.' ? '' : rel,
      );
      if (out != text) {
        f.writeAsStringSync(out);
        report.changed.add(p.relative(f.path, from: root));
      }
    }
  }

  if (moveDirectories) _moveDirectories(root, packageDirs, names, report);

  if (rekey) {
    for (final MapEntry(key: old, value: dir) in report.packageDirs.entries) {
      final manifest = File(
        p.join(root, dir, 'native_artifacts', 'prebuilt.json'),
      );
      if (!manifest.existsSync()) continue;
      final error = await _rekey(p.join(root, dir), manifest);
      if (error != null) {
        report.errors.add('${names[old]!.name}: Kiln source key: $error');
      } else {
        report.changed.add(p.relative(manifest.path, from: root));
      }
    }
  }
  return report;
}

bool _inExample(String rel) => p
    .split(rel)
    .any(
      (s) =>
          s == 'example' || s.startsWith('example') || s.endsWith('_example'),
    );

Iterable<File> _files(Directory dir) sync* {
  for (final e in dir.listSync(followLinks: false)) {
    if (e is Directory) {
      if (!_skipDirs.contains(p.basename(e.path))) yield* _files(e);
    } else if (e is File) {
      yield e;
    }
  }
}

final _sections = ['dependencies', 'dev_dependencies', 'dependency_overrides'];

/// A pubspec with the package and its dependencies at their published
/// names. In a published pubspec, a path dependency on a package of this
/// repository becomes `^version`, and a git or path dependency on a
/// renamed package with a version in [names] becomes that version.
String renamePubspec(
  String text,
  Map<String, PublishName> names,
  Map<String, String> versions, {
  bool published = true,
  void Function(String error)? onError,
}) {
  final doc = loadYamlNode(text);
  if (doc is! YamlMap) return text;
  final edits = <(int, int, String)>[];
  void replace(YamlNode node, String to) =>
      edits.add((node.span.start.offset, node.span.end.offset, to));

  final nameNode = doc.nodes['name'];
  if (nameNode is YamlScalar) {
    if (names[nameNode.value] case final n?) replace(nameNode, n.name);
  }
  for (final section in _sections) {
    final deps = doc.nodes[section];
    if (deps is! YamlMap) continue;
    for (final MapEntry(key: keyNode, :value) in deps.nodes.entries) {
      final dep = (keyNode as YamlScalar).value as String;
      final renamed = names[dep];
      if (renamed != null) replace(keyNode, renamed.name);
      if (!published || section == 'dependency_overrides') continue;
      if (value is! YamlMap) continue;
      final isPath = value.containsKey('path'),
          isGit = value.containsKey('git');
      if (!isPath && !isGit) continue;
      final constraint =
          renamed?.version ??
          (isPath && versions[dep] != null ? '^${versions[dep]}' : null);
      if (constraint != null) {
        replace(value, constraint);
      } else if (section == 'dependencies') {
        onError?.call(
          '$dep is a ${isPath ? 'path' : 'git'} dependency with no version: '
          'give it one in $publishNamesPath.',
        );
      }
    }
  }
  final flutter = doc.nodes['flutter'];
  final plugin = flutter is YamlMap ? flutter.nodes['plugin'] : null;
  if (plugin is YamlMap) {
    if (plugin.nodes['implements'] case final YamlScalar s
        when names.containsKey(s.value)) {
      replace(s, names[s.value]!.name);
    }
    if (plugin.nodes['platforms'] case final YamlMap platforms) {
      for (final platform in platforms.nodes.values) {
        if (platform is! YamlMap) continue;
        if (platform.nodes['default_package'] case final YamlScalar s
            when names.containsKey(s.value)) {
          replace(s, names[s.value]!.name);
        }
      }
    }
  }
  return _apply(text, edits, block: true);
}

/// Applies [edits]; a block value replaced by a scalar goes on its key's
/// line.
String _apply(
  String text,
  List<(int, int, String)> edits, {
  bool block = false,
}) {
  edits.sort((a, b) => b.$1.compareTo(a.$1));
  var out = text;
  for (final (start, end, to) in edits) {
    var s = start;
    if (block && to.startsWith('^')) {
      // A map value starts on the next line: put the scalar after "key:".
      final colon = out.lastIndexOf(':', s);
      if (colon >= 0 && out.substring(colon + 1, s).trim().isEmpty) {
        s = colon + 1;
        var e = end;
        while (e > s && (out[e - 1] == '\n' || out[e - 1] == ' ')) {
          e--;
        }
        out = '${out.substring(0, s)} $to${out.substring(e)}';
        continue;
      }
    }
    out = out.replaceRange(s, end, to);
  }
  return out;
}

String _old(String name) => RegExp.escape(name);

/// A pubspec whose `repository` is [repository] at [ref] (the renamed
/// sources that were published: pub.dev checks that the repository has a
/// pubspec with the published name) and whose `issue_tracker` is the
/// fork's: users of the published name report to us. `homepage` stays
/// (upstream's, credit).
String setRepository(
  String text,
  String repository, {
  required String ref,
  String path = '',
}) {
  final base = repository.endsWith('/')
      ? repository.substring(0, repository.length - 1)
      : repository;
  final url = path.isEmpty && ref == 'main'
      ? base
      : '$base/tree/$ref${path.isEmpty ? '' : '/$path'}';
  var out = text;
  for (final (key, value) in [
    ('repository', url),
    ('issue_tracker', '$base/issues'),
  ]) {
    final line = RegExp('^$key:.*\$', multiLine: true);
    out = line.hasMatch(out)
        ? out.replaceFirst(line, '$key: $value')
        : out.replaceFirstMapped(
            RegExp(r'^(version:.*)$', multiLine: true),
            (m) => '${m[1]}\n$key: $value',
          );
  }
  return out;
}

/// `package:old/` to `package:new/` (imports, exports, and strings: asset
/// IDs, type checker URIs), and analyzer_buffer's `#{{old|Symbol}}`.
String renameDart(String text, Map<String, PublishName> names) {
  var out = text;
  for (final MapEntry(:key, :value) in names.entries) {
    out = out
        .replaceAll(RegExp('(?<=package:)${_old(key)}(?=/)'), value.name)
        .replaceAll(RegExp('(?<=#\\{\\{)${_old(key)}(?=\\|)'), value.name);
  }
  return out;
}

/// Whether [file] is in lib, bin or hook of one of [packageDirs].
bool _isPublishedCode(String file, Iterable<String> packageDirs) {
  for (final dir in packageDirs) {
    if (!p.isWithin(dir, file)) continue;
    final first = p.split(p.relative(file, from: dir)).first;
    if (const {'lib', 'bin', 'hook'}.contains(first)) return true;
  }
  return false;
}

/// Renames or keeps each string that is only an old name, by the rules
/// of [config] for the text before it; one no rule matches is an error.
String _renameStrings(
  String text,
  String rel,
  PublishNames config,
  RenameReport report,
) {
  final names = config.names.keys.map(_old).join('|');
  final string = RegExp('([\'"])($names)\\1');
  final lines = text.split('\n');
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    if (line.trimLeft().startsWith('//')) continue;
    lines[i] = line.replaceAllMapped(string, (m) {
      final before =
          '${p.posix.joinAll(p.split(rel))}:'
          '${line.substring(0, m.start)}';
      final where = '$rel:${i + 1}: ${line.trim()}';
      if (config.renameLines.any((r) => r.hasMatch(before))) {
        report.renamedStrings.add(where);
        return '${m[1]}${config.names[m[2]]!.name}${m[1]}';
      }
      if (config.keepLines.any((r) => r.hasMatch(before))) {
        report.keptStrings.add(where);
        return m[0]!;
      }
      report.errors.add(
        '$where\n    ${m[0]}: a string that is only an old name. Add a rule '
        'for the text before it to strings.rename or strings.keep in '
        '$publishNamesPath.',
      );
      return m[0]!;
    });
  }
  return lines.join('\n');
}

/// Every old name, as a whole word, on the lines that match [config]'s
/// `lines` (against `path:line`).
String _renameLines(String text, String rel, PublishNames config) {
  final path = p.posix.joinAll(p.split(rel));
  final word = RegExp(
    '(?<![\\w/])(${config.names.keys.map(_old).join('|')})(?!\\w)',
  );
  final lines = text.split('\n');
  for (var i = 0; i < lines.length; i++) {
    if (!config.lines.any((r) => r.hasMatch('$path:${lines[i]}'))) continue;
    lines[i] = lines[i].replaceAllMapped(word, (m) => config.names[m[1]]!.name);
  }
  return lines.join('\n');
}

/// build.yaml: builder references `old:builder` and `old|builder`, and
/// `package:old/` imports. Builder names (map keys) stay.
String renameBuildYaml(String text, Map<String, PublishName> names) {
  var out = renameDart(text, names);
  for (final MapEntry(:key, :value) in names.entries) {
    out = out.replaceAll(
      RegExp('(?<![\\w.-])${_old(key)}(?=[:|][A-Za-z_])'),
      value.name,
    );
  }
  return out;
}

/// analysis_options.yaml: analyzer plugins, keyed by package name.
String renameAnalysisOptions(String text, Map<String, PublishName> names) {
  var out = renameDart(text, names);
  for (final MapEntry(:key, :value) in names.entries) {
    out = out.replaceAllMapped(
      RegExp('^(\\s+(?:- )?)${_old(key)}(?=:|\\s*\$)', multiLine: true),
      (m) => '${m[1]}${value.name}',
    );
  }
  return out;
}

/// The parts of a plugin's native code that Flutter finds by package name:
/// - Darwin: `<name>.podspec` and its `s.name`; the Swift package at
///   `<platform>/<name>/`, its target and module `<name>`, its library
///   `<name with ->`; public headers in `include/<name>/`.
/// - Linux, Windows: the CMake target `<name>_plugin`, the include
///   directory `include/<name>/`, and `<name>_bundled_libraries`.
/// Any file or directory named `<name>` moves; `<name>.podspec` too.
void _renameNative(
  String root,
  Directory platformDir,
  String old,
  String renamed,
  RenameReport report,
) {
  final o = _old(old);
  final dashedOld = old.replaceAll('_', '-');
  final dashedNew = renamed.replaceAll('_', '-');
  for (final f in _files(platformDir)) {
    final base = p.basename(f.path);
    String text;
    try {
      text = f.readAsStringSync();
    } on FileSystemException {
      continue;
    }
    var out = text;
    if (base.endsWith('.podspec') || base == 'Package.swift') {
      out = out
          // Quoted names: s.name, package, target, product names.
          .replaceAllMapped(
            RegExp('([\'"])$o\\1'),
            (m) => '${m[1]}$renamed${m[1]}',
          )
          .replaceAllMapped(
            RegExp('([\'"])${RegExp.escape(dashedOld)}\\1'),
            (m) => '${m[1]}$dashedNew${m[1]}',
          )
          // Path segments: '<old>/Sources/<old>/**', 'Classes/<old>/'.
          .replaceAllMapped(RegExp('(?<=[\'"/])$o(?=/)'), (m) => renamed);
    } else if (base == 'CMakeLists.txt' || base.endsWith('.cmake')) {
      out = out
          .replaceAllMapped(
            RegExp('(?<![\\w])${o}_(plugin|bundled_libraries)(?![\\w.])'),
            (m) => '${renamed}_${m[1]}',
          )
          .replaceAllMapped(RegExp('"$o"'), (m) => '"$renamed"')
          .replaceAllMapped(RegExp('(?<=include/)$o(?=/)'), (m) => renamed);
    } else if (RegExp(r'\.(c|cc|cpp|h|hpp|m|mm|swift)$').hasMatch(base)) {
      out = out
          .replaceAllMapped(RegExp('(?<=include/)$o(?=/)'), (m) => renamed)
          .replaceAllMapped(RegExp('(?<=[<"])$o(?=/)'), (m) => renamed)
          .replaceAllMapped(
            RegExp('(?<=^\\s*(?:@?import)\\s+)$o\\b', multiLine: true),
            (m) => renamed,
          );
    }
    if (out != text) {
      f.writeAsStringSync(out);
      report.changed.add(p.relative(f.path, from: root));
    }
  }
  // Move files and directories named after the package, deepest first.
  final entities = platformDir.listSync(recursive: true, followLinks: false)
    ..sort((a, b) => b.path.length.compareTo(a.path.length));
  for (final e in entities) {
    final base = p.basename(e.path);
    final String to;
    if (base == old) {
      to = renamed;
    } else if (base == '$old.podspec') {
      to = '$renamed.podspec';
    } else {
      continue;
    }
    final dest = p.join(p.dirname(e.path), to);
    e.renameSync(dest);
    report.moved[p.relative(e.path, from: root)] = p.relative(dest, from: root);
  }
}

/// Moves each package directory named after its old name to the new name,
/// and fixes the paths to it in the repository's pubspecs (path
/// dependencies, workspace members). For builds of a renamed checkout:
/// Flutter's Swift packages take a path dependency's identity from its
/// directory name. (In the pub cache, the directory is the new name.)
void _moveDirectories(
  String root,
  Map<String, String> packageDirs,
  Map<String, PublishName> names,
  RenameReport report,
) {
  final moves = <String, String>{}; // old name -> new name, of directories
  for (final MapEntry(key: old, value: dir) in packageDirs.entries) {
    if (p.basename(dir) != old || p.equals(dir, root)) continue;
    final to = p.join(p.dirname(dir), names[old]!.name);
    Directory(dir).renameSync(to);
    moves[old] = names[old]!.name;
    report.moved[p.relative(dir, from: root)] = p.relative(to, from: root);
    report.packageDirs[old] = p.relative(to, from: root);
  }
  if (moves.isEmpty) return;
  final segment = RegExp(
    '(?<=^|[/\\s\'"])(${moves.keys.map(_old).join('|')})(?=/|\\s*\$|[\'"])',
  );
  for (final f in _files(Directory(root))) {
    final base = p.basename(f.path);
    if (base != 'pubspec.yaml' && base != 'pubspec_overrides.yaml') continue;
    final text = f.readAsStringSync();
    final lines = text.split('\n');
    var inWorkspace = false;
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (RegExp(r'^\S').hasMatch(line)) {
        inWorkspace = line.startsWith('workspace:');
      }
      final value = RegExp(r'^(\s*(?:path:|-)\s*)(.*)$').firstMatch(line);
      if (value == null || (!line.contains('path:') && !inWorkspace)) continue;
      lines[i] =
          value[1]! + value[2]!.replaceAllMapped(segment, (m) => moves[m[1]]!);
    }
    final out = lines.join('\n');
    if (out != text) {
      f.writeAsStringSync(out);
      report.changed.add(p.relative(f.path, from: root));
    }
  }
}

/// Sets the manifest's source key to the renamed sources' key: the
/// prebuilt files are the same, only names in the sources changed.
Future<String?> _rekey(String dir, File manifest) async {
  final get = await Process.run(
    'dart',
    ['pub', 'get'],
    workingDirectory: dir,
    runInShell: Platform.isWindows,
  );
  if (get.exitCode != 0) return 'pub get: ${get.stderr}'.trim();
  final run = await Process.run(
    'dart',
    ['run', 'kiln:key'],
    workingDirectory: dir,
    runInShell: Platform.isWindows,
  );
  final key = RegExp(r'\b[0-9a-f]{64}\b').firstMatch('${run.stdout}')?[0];
  if (run.exitCode != 0 || key == null) {
    return 'kiln:key: ${run.stderr}${run.stdout}'.trim();
  }
  final text = manifest.readAsStringSync();
  manifest.writeAsStringSync(
    text.replaceFirst(
      RegExp(r'"sourceKey":\s*"[0-9a-f]{64}"'),
      '"sourceKey": "$key"',
    ),
  );
  return null;
}

/// The package a release tag publishes, from a (renamed) checkout:
/// `v1.2.3` the repository's only published package, `name-v1.2.3` the
/// package `name`. Its directory relative to [root], or an error.
({String? dir, String? error}) packageForTag(String root, String tag) {
  final m = RegExp(
    r'^(?:([a-z][a-z0-9_]*)-)?v(\d+\.\d+\.\d+\S*)$',
  ).firstMatch(tag);
  if (m == null) {
    return (
      dir: null,
      error: 'Tag "$tag" is not v<version> or <package>-v<version>.',
    );
  }
  final wanted = m[1], version = m[2]!;
  final found = <String, (String, String?)>{}; // name -> (dir, version)
  for (final f in _files(Directory(root))) {
    if (p.basename(f.path) != 'pubspec.yaml') continue;
    final rel = p.relative(f.parent.path, from: root);
    if (_inExample(rel)) continue;
    final doc = loadYaml(f.readAsStringSync());
    if (doc is! YamlMap || doc['name'] is! String) continue;
    if (doc['publish_to'] == 'none' || doc['workspace'] != null) continue;
    found[doc['name'] as String] = (rel, doc['version'] as String?);
  }
  final String name;
  if (wanted != null) {
    if (!found.containsKey(wanted)) {
      return (
        dir: null,
        error:
            'No published package "$wanted" (tag $tag); found: '
            '${(found.keys.toList()..sort()).join(', ')}.',
      );
    }
    name = wanted;
  } else if (found.length == 1) {
    name = found.keys.single;
  } else {
    return (
      dir: null,
      error:
          'Tag $tag names no package, and the repository has '
          '${found.length}: use <package>-v<version>.',
    );
  }
  final (dir, pubspecVersion) = found[name]!;
  if (pubspecVersion != version) {
    return (
      dir: null,
      error:
          '$name is version $pubspecVersion in its pubspec, the tag says '
          '$version.',
    );
  }
  return (dir: dir, error: null);
}
