/// The files of the tree that `dart pub publish --dry-run` prints, relative
/// to the package, with `/`.
List<String> publishedFiles(String dryRunOutput) {
  final entry = RegExp(r'^((?:│   |    )*)(?:├── |└── )(.+)$');
  final size = RegExp(r' \((?:<?[0-9.]+ (?:B|KB|MB|GB))\)$');
  final files = <String>[];
  final path = <String>[];
  for (final line in dryRunOutput.split('\n')) {
    final m = entry.firstMatch(line);
    if (m == null) continue;
    final depth = m[1]!.length ~/ 4;
    final name = m[2]!;
    path.length = depth;
    if (size.hasMatch(name)) {
      files.add([...path, name.replaceFirst(size, '')].join('/'));
    } else {
      path.add(name);
    }
  }
  return files;
}
