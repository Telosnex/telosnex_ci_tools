import 'lint.dart' show selfRepository;

/// A `uses:` of an action or reusable workflow of this repository, pinned to
/// a commit, with its optional `# vX.Y.Z` comment.
final _toolsPin = RegExp(
  '(${RegExp.escape(selfRepository)}/[^@\\s\'"]+)@[0-9a-f]{40}'
  r'''(?:[ \t]*#[ \t]*v\d+\.\d+\.\d+\S*)?''',
);

/// [text] with every reference to this repository pinned to [sha], with the
/// comment [tag]. Lines that pin it with `# self` (this repository's own
/// workflows, see pin_self) are left alone.
String repin(String text, String sha, String tag) => text
    .split('\n')
    .map(
      (line) => line.contains('# self')
          ? line
          : line.replaceAllMapped(_toolsPin, (m) => '${m[1]}@$sha # $tag'),
    )
    .join('\n');

/// Whether [text] refers to this repository with a commit pin.
bool usesTools(String text) => _toolsPin.hasMatch(text);

/// The release tags of this repository, `vX.Y.Z`.
final releaseTag = RegExp(r'^v\d+\.\d+\.\d+$');
