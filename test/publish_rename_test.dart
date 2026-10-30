import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:telosnex_ci_tools/src/publish_rename.dart';
import 'package:test/test.dart';

const _names = {
  'foo': PublishName('telosnex_foo'),
  'foo_platform_interface': PublishName('telosnex_foo_platform_interface'),
  'bar': PublishName('telosnex_bar', version: '^2.0.0'),
};

Future<(Directory, RenameReport)> _rename(
  Map<String, String> files, {
  String config = '',
}) async {
  final root = Directory.systemTemp.createTempSync('publish_rename');
  addTearDown(() => root.deleteSync(recursive: true));
  for (final MapEntry(:key, :value) in files.entries) {
    File(p.join(root.path, key))
      ..createSync(recursive: true)
      ..writeAsStringSync(value);
  }
  final names = parsePublishNames('''
names:
  foo: telosnex_foo
  foo_platform_interface: telosnex_foo_platform_interface
  bar: {name: telosnex_bar, version: ^2.0.0}
$config''');
  final report = await renameRepository(root.path, names, rekey: false);
  return (root, report);
}

String _read(Directory root, String path) =>
    File(p.join(root.path, path)).readAsStringSync();

void main() {
  group('parsePublishNames', () {
    test('names, versions, string rules', () {
      final config = parsePublishNames(r'''
names:
  foo: telosnex_foo
  bar: {name: telosnex_bar, version: ^2.0.0}
strings:
  rename: ['packageName: $']
  keep: ['MethodChannel\($']
lines: ['^test/']
''');
      expect(config.names['foo']!.name, 'telosnex_foo');
      expect(config.names['bar']!.version, '^2.0.0');
      expect(config.renameLines.single.pattern, r'packageName: $');
      expect(config.keepLines, hasLength(1));
      expect(config.lines, hasLength(1));
    });

    test('refuses a name that is no package name', () {
      expect(
        () => parsePublishNames('names:\n  foo: Telosnex-Foo\n'),
        throwsFormatException,
      );
      expect(() => parsePublishNames('foo: bar\n'), throwsFormatException);
    });
  });

  group('renamePubspec', () {
    test('name, dependencies, path to ^version, plugin keys', () {
      const pubspec = '''
name: foo
version: 1.2.3
dependencies:
  foo_platform_interface:
    path: ../foo_platform_interface
  bar:
    git:
      url: https://github.com/Telosnex/bar
  http: ^1.0.0
dev_dependencies:
  foo_platform_interface:
    path: ../foo_platform_interface
flutter:
  plugin:
    implements: foo_platform_interface
    platforms:
      android:
        default_package: foo
''';
      final out = renamePubspec(pubspec, _names, {
        'foo_platform_interface': '4.5.6',
      });
      expect(out, contains('name: telosnex_foo\n'));
      expect(out, contains('  telosnex_foo_platform_interface: ^4.5.6\n'));
      expect(out, contains('  telosnex_bar: ^2.0.0\n'));
      expect(out, contains('  http: ^1.0.0\n'));
      expect(out, contains('implements: telosnex_foo_platform_interface'));
      expect(out, contains('default_package: telosnex_foo'));
      expect(out, isNot(contains('path:')));
      expect(out, isNot(contains('git:')));
    });

    test('an example keeps its path dependencies', () {
      const pubspec =
          'name: foo_example\ndependencies:\n  foo:\n    path: ../\n';
      final out = renamePubspec(pubspec, _names, {
        'foo': '1.0.0',
      }, published: false);
      expect(
        out,
        'name: foo_example\ndependencies:\n  telosnex_foo:\n    path: ../\n',
      );
    });

    test('a git dependency with no version is an error', () {
      final errors = <String>[];
      renamePubspec(
        'name: foo\ndependencies:\n  other:\n    git: https://x/other\n',
        _names,
        {},
        onError: errors.add,
      );
      expect(errors.single, contains('other is a git dependency'));
    });
  });

  test('renameDart: package URIs and analyzer_buffer codes only', () {
    const dart = '''
import 'package:foo/foo.dart';
import 'package:foo_platform_interface/x.dart';
import 'package:food/food.dart';
const a = 'package:foo/src/a.dart';
const code = '#{{foo|Thing}}';
const word = 'foo';
''';
    expect(renameDart(dart, _names), '''
import 'package:telosnex_foo/foo.dart';
import 'package:telosnex_foo_platform_interface/x.dart';
import 'package:food/food.dart';
const a = 'package:telosnex_foo/src/a.dart';
const code = '#{{telosnex_foo|Thing}}';
const word = 'foo';
''');
  });

  group('strings that are only an old name', () {
    const files = {
      'pubspec.yaml': 'name: foo\nversion: 1.0.0\n',
      'lib/a.dart': '''
const t = TypeChecker.fromName('X', packageName: 'foo');
const c = MethodChannel('foo');
// A comment: 'foo'.
''',
      'test/a_test.dart': "const s = 'foo';\n",
    };

    test('renamed or kept by the text before them', () async {
      final (root, report) = await _rename(
        files,
        config: r'''
strings:
  rename: ['packageName: $']
  keep: ['MethodChannel\($']
''',
      );
      expect(report.errors, isEmpty);
      expect(_read(root, 'lib/a.dart'), '''
const t = TypeChecker.fromName('X', packageName: 'telosnex_foo');
const c = MethodChannel('foo');
// A comment: 'foo'.
''');
      expect(report.renamedStrings, hasLength(1));
      expect(report.keptStrings, hasLength(1));
      // Tests are not published code: untouched, no error.
      expect(_read(root, 'test/a_test.dart'), "const s = 'foo';\n");
    });

    test('with no rule: an error', () async {
      final (_, report) = await _rename(files);
      expect(report.errors, hasLength(2));
      expect(report.errors.first, contains("lib/a.dart:1"));
    });

    test('lines: every old name on a matching line', () async {
      final (root, report) = await _rename({
        'test/pub_test.dart': "final p = '''\n  foo:\n  food:\n''';\n",
      }, config: "lines: ['^test/pub_test\\.dart:\\s+foo:']\n");
      expect(report.errors, isEmpty);
      expect(
        _read(root, 'test/pub_test.dart'),
        "final p = '''\n  telosnex_foo:\n  food:\n''';\n",
      );
    });
  });

  test('build.yaml and analysis_options.yaml', () async {
    final (root, _) = await _rename({
      'build.yaml': '''
builders:
  foo:
    import: "package:foo/builder.dart"
    applies_builders: ["foo:foo", "source_gen|combining_builder"]
''',
      'analysis_options.yaml': 'plugins:\n  foo:\n    path: x\n',
    });
    expect(_read(root, 'build.yaml'), '''
builders:
  foo:
    import: "package:telosnex_foo/builder.dart"
    applies_builders: ["telosnex_foo:foo", "source_gen|combining_builder"]
''');
    expect(
      _read(root, 'analysis_options.yaml'),
      'plugins:\n  telosnex_foo:\n    path: x\n',
    );
  });

  test(
    '--move-directories: package directories and the paths to them',
    () async {
      final root = Directory.systemTemp.createTempSync('publish_rename');
      addTearDown(() => root.deleteSync(recursive: true));
      for (final MapEntry(:key, :value) in {
        'pubspec.yaml': 'name: ws\nworkspace:\n  - foo\n  - foo/example\n',
        'foo/pubspec.yaml':
            'name: foo\nversion: 1.0.0\nresolution: workspace\n',
        'foo/example/pubspec.yaml':
            'name: foo_example\ndependencies:\n  foo:\n    path: ../\n',
        'other/pubspec.yaml':
            'name: other\ndependencies:\n  foo:\n    path: ../foo\n',
      }.entries) {
        File(p.join(root.path, key))
          ..createSync(recursive: true)
          ..writeAsStringSync(value);
      }
      final report = await renameRepository(
        root.path,
        parsePublishNames('names:\n  foo: telosnex_foo\n'),
        rekey: false,
        moveDirectories: true,
      );
      expect(report.errors, isEmpty);
      expect(report.moved, {'foo': 'telosnex_foo'});
      expect(
        _read(root, 'pubspec.yaml'),
        'name: ws\nworkspace:\n  - telosnex_foo\n  - telosnex_foo/example\n',
      );
      expect(
        _read(root, 'telosnex_foo/pubspec.yaml'),
        contains('name: telosnex_foo'),
      );
      // "other" is published: its path dependency became a version.
      expect(
        _read(root, 'other/pubspec.yaml'),
        contains('telosnex_foo: ^1.0.0'),
      );
      expect(
        _read(root, 'telosnex_foo/example/pubspec.yaml'),
        contains('path: ../\n'),
      );
    },
  );

  test('native files Flutter finds by package name', () async {
    final (root, report) = await _rename({
      'pubspec.yaml': 'name: foo\nversion: 1.0.0\n',
      'ios/foo.podspec': """
Pod::Spec.new do |s|
  s.name = 'foo'
  s.source_files = 'foo/Sources/foo/**/*.swift'
  s.resource_bundles = {'foo_privacy' => ['foo/Sources/foo/PrivacyInfo.xcprivacy']}
end
""",
      'ios/foo/Package.swift': '''
let package = Package(
    name: "foo",
    products: [.library(name: "foo", targets: ["foo"])],
    targets: [.target(name: "foo")]
)
''',
      'ios/foo/Sources/foo/FooPlugin.swift': 'import Flutter\n',
      'linux/CMakeLists.txt': '''
set(PROJECT_NAME "foo")
set(PLUGIN_NAME "foo_plugin")
list(APPEND PLUGIN_SOURCES "foo_plugin.cc")
set(foo_bundled_libraries "" PARENT_SCOPE)
''',
      'linux/foo_plugin.cc': '#include "include/foo/foo_plugin.h"\n',
      'linux/include/foo/foo_plugin.h': '',
    });
    expect(report.errors, isEmpty);
    final podspec = _read(root, 'ios/telosnex_foo.podspec');
    expect(podspec, contains("s.name = 'telosnex_foo'"));
    expect(podspec, contains("'telosnex_foo/Sources/telosnex_foo/**/*.swift'"));
    // The bundle name is no package name.
    expect(podspec, contains("'foo_privacy'"));
    final swift = _read(root, 'ios/telosnex_foo/Package.swift');
    expect(swift, contains('name: "telosnex_foo"'));
    expect(swift, isNot(contains('"foo"')));
    expect(
      File(
        p.join(
          root.path,
          'ios/telosnex_foo/Sources/telosnex_foo/FooPlugin.swift',
        ),
      ).existsSync(),
      isTrue,
    );
    final cmake = _read(root, 'linux/CMakeLists.txt');
    expect(cmake, contains('"telosnex_foo"'));
    expect(cmake, contains('"telosnex_foo_plugin"'));
    // Source files keep their names: Flutter includes the plugin class's.
    expect(cmake, contains('"foo_plugin.cc"'));
    expect(cmake, contains('set(telosnex_foo_bundled_libraries'));
    expect(
      _read(root, 'linux/foo_plugin.cc'),
      '#include "include/telosnex_foo/foo_plugin.h"\n',
    );
    expect(
      File(
        p.join(root.path, 'linux/include/telosnex_foo/foo_plugin.h'),
      ).existsSync(),
      isTrue,
    );
  });

  group('packageForTag', () {
    Directory repo(Map<String, String> pubspecs) {
      final root = Directory.systemTemp.createTempSync('publish_tag');
      addTearDown(() => root.deleteSync(recursive: true));
      for (final MapEntry(:key, :value) in pubspecs.entries) {
        File(p.join(root.path, key, 'pubspec.yaml'))
          ..createSync(recursive: true)
          ..writeAsStringSync(value);
      }
      return root;
    }

    test('v<version>: the only published package', () {
      final root = repo({
        '.': 'name: foo\nversion: 1.2.3\n',
        'example': 'name: foo_example\npublish_to: none\n',
      });
      expect(packageForTag(root.path, 'v1.2.3'), (dir: '.', error: null));
      expect(
        packageForTag(root.path, 'v1.2.4').error,
        contains('version 1.2.3 in its pubspec'),
      );
    });

    test('<package>-v<version> in a repository of several', () {
      final root = repo({
        '.': 'name: ws\nworkspace:\n  - packages/a\n',
        'packages/a': 'name: telosnex_a\nversion: 2.0.0-dev.1\n',
        'packages/b': 'name: telosnex_b\nversion: 1.0.0\n',
      });
      expect(packageForTag(root.path, 'telosnex_a-v2.0.0-dev.1'), (
        dir: 'packages/a',
        error: null,
      ));
      expect(packageForTag(root.path, 'v1.0.0').error, contains('has 2'));
      expect(
        packageForTag(root.path, 'c-v1.0.0').error,
        contains('No published'),
      );
      expect(packageForTag(root.path, 'release-1').error, contains('is not'));
    });
  });
}
