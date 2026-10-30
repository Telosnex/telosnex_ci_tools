import 'package:telosnex_ci_tools/src/published_files.dart';
import 'package:test/test.dart';

void main() {
  test('the file tree of pub publish --dry-run', () {
    const out = '''
Publishing fonnx 0.1.0 to https://pub.dev:
├── CHANGELOG.md (<1 KB)
├── LICENSE (36 KB)
├── hook
│   └── build.dart (12 KB)
├── lib
│   ├── fonnx.dart (2 KB)
│   └── src
│       └── a b.dart (1 MB)
└── pubspec.yaml (1 KB)

Total compressed archive size: 2 MB.
''';
    expect(publishedFiles(out), [
      'CHANGELOG.md',
      'LICENSE',
      'hook/build.dart',
      'lib/fonnx.dart',
      'lib/src/a b.dart',
      'pubspec.yaml',
    ]);
  });
}
