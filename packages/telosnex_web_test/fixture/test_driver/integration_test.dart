import 'package:telosnex_web_test/driver.dart';

// Polls every 2 s, so the short fixture run shows progress lines.
Future<void> main() =>
    webIntegrationDriver(pollInterval: const Duration(seconds: 2));
