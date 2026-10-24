import 'package:test/test.dart';

import '../actions/kiln-build/kiln_build.dart';

void main() {
  test('matchesTarget', () {
    expect(matchesTarget('android-*', 'android-arm64'), isTrue);
    expect(matchesTarget('android-*', 'linux-arm64'), isFalse);
    expect(matchesTarget('*-x64', 'windows-x64'), isTrue);
    expect(matchesTarget('windows-x64', 'windows-x64'), isTrue);
    expect(matchesTarget('windows-x64', 'windows-x64-extra'), isFalse);
    expect(matchesTarget('ios-*.x', 'ios-abx'), isFalse);
  });

  test('argsFor gives the arguments of every matching pattern in order', () {
    const json = '''
{
  "*": ["--ios-version", "15"],
  "android-*": ["--define", "android_ndk_home=\${ANDROID_NDK_HOME}"],
  "windows-x64": ["--define", "cuda_pack=\${OUT}/cuda/windows-x64.json"]
}''';
    final env = {'ANDROID_NDK_HOME': '/ndk', 'OUT': '/out'};
    expect(argsFor(json, 'android-arm', env), [
      '--ios-version',
      '15',
      '--define',
      'android_ndk_home=/ndk',
    ]);
    expect(argsFor(json, 'windows-x64', env), [
      '--ios-version',
      '15',
      '--define',
      'cuda_pack=/out/cuda/windows-x64.json',
    ]);
    expect(argsFor('', 'linux-x64', env), isEmpty);
  });

  test('a missing variable is an error', () {
    expect(
      () => argsFor('{"*": ["\${NOPE}"]}', 'linux-x64', {}),
      throwsFormatException,
    );
  });

  test('androidDefines', () {
    final env = {'ANDROID_NDK_HOME': '/ndk'};
    expect(androidDefines('android-arm64', env), [
      '--define',
      'android_ndk_home=/ndk',
    ]);
    expect(
      androidDefines('android-arm64', {
        ...env,
        'ANDROID_HOME': '/sdk',
        'NDK_VERSION': '28.2',
      }),
      [
        '--define',
        'android_ndk_home=/ndk',
        '--define',
        'android={"android_home":"/sdk","ndk_version":"28.2"}',
      ],
    );
    expect(androidDefines('linux-x64', env), isNull);
    expect(androidDefines('android-arm64', {}), isNull);
  });
}
