import 'package:telosnex_ci_tools/src/release.dart';
import 'package:test/test.dart';

void main() {
  const old = '0123456789012345678901234567890123456789';
  const sha = 'abcdefabcdefabcdefabcdefabcdefabcdefabcd';

  test('repins actions and reusable workflows, with or without a comment', () {
    const text =
        '''
      - uses: Telosnex/telosnex_ci_tools/actions/setup-flutter@$old # v0.5.3
      - uses: Telosnex/telosnex_ci_tools/actions/lint@$old
    uses: Telosnex/telosnex_ci_tools/.github/workflows/kiln_release.yml@$old # v0.5.4
''';
    expect(repin(text, sha, 'v0.5.6'), '''
      - uses: Telosnex/telosnex_ci_tools/actions/setup-flutter@$sha # v0.5.6
      - uses: Telosnex/telosnex_ci_tools/actions/lint@$sha # v0.5.6
    uses: Telosnex/telosnex_ci_tools/.github/workflows/kiln_release.yml@$sha # v0.5.6
''');
  });

  test('leaves other actions and # self pins alone', () {
    const text =
        '''
      - uses: actions/checkout@$old # v6.0.0
      - uses: Telosnex/telosnex_ci_tools/actions/setup-flutter@$old # self
      - uses: Telosnex/other/actions/x@$old # v1.0.0
''';
    expect(repin(text, sha, 'v0.5.6'), text);
    expect(usesTools(text), isTrue);
    expect(
      usesTools('      - uses: actions/checkout@$old # v6.0.0\n'),
      isFalse,
    );
  });

  test('release tags', () {
    expect(releaseTag.hasMatch('v0.5.6'), isTrue);
    expect(releaseTag.hasMatch('v0'), isFalse);
    expect(releaseTag.hasMatch('0.5.6'), isFalse);
  });
}
