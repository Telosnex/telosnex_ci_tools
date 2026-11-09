// A fixture of actions/android-arm64-container (ci.yml): one test fails, so
// the run must fail.
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('passes', () => expect(1, 1));
  test('fails', () => expect(1, 2));
}
