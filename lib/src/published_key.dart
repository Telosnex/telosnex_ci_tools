/// A listing of `kiln:key --list`: path to SHA-256, and the key.
final class KeyListing {
  KeyListing(this.files, this.key);

  /// Parses the standard output of `kiln:key --list`: one `path<TAB>sha256`
  /// line per file, then the key.
  factory KeyListing.parse(String output) {
    final files = <String, String>{};
    String? key;
    for (final line in output.split('\n')) {
      final tab = line.indexOf('\t');
      if (tab > 0) {
        files[line.substring(0, tab)] = line.substring(tab + 1).trim();
      } else if (RegExp(r'^[0-9a-f]{64}$').hasMatch(line.trim())) {
        key = line.trim();
      }
    }
    if (key == null) throw FormatException('No source key in:\n$output');
    return KeyListing(files, key);
  }

  final Map<String, String> files;
  final String key;
}

/// Why the key of the checkout and the key of the published files differ,
/// one line per file.
List<String> keyDifferences(KeyListing checkout, KeyListing published) => [
  for (final path in checkout.files.keys.toList()..sort())
    if (!published.files.containsKey(path))
      '  in the key, not published: $path'
    else if (published.files[path] != checkout.files[path])
      '  published with other content: $path',
  for (final path in published.files.keys.toList()..sort())
    if (!checkout.files.containsKey(path))
      '  published, not in the key here: $path',
];
