import 'package:telosnex_ci_tools/src/published_key.dart';
import 'package:test/test.dart';

void main() {
  final key = 'a' * 64;

  test('parses the listing of kiln:key --list', () {
    final listing = KeyListing.parse(
      'hook/build.dart\t11\nsrc/a b.c\t22\n$key\n',
    );
    expect(listing.files, {'hook/build.dart': '11', 'src/a b.c': '22'});
    expect(listing.key, key);
  });

  test('a listing without a key is an error', () {
    expect(() => KeyListing.parse('a\t11\n'), throwsFormatException);
  });

  test('names the tracked file that pub leaves out', () {
    final checkout = KeyListing({
      'src/build-xcframework.sh': '1',
      'src/a.c': '2',
      'src/b.c': '3',
    }, key);
    final published = KeyListing({
      'src/a.c': '2',
      'src/b.c': '9',
      'extra.txt': '4',
    }, key);
    expect(keyDifferences(checkout, published), [
      '  published with other content: src/b.c',
      '  in the key, not published: src/build-xcframework.sh',
      '  published, not in the key here: extra.txt',
    ]);
  });
}
