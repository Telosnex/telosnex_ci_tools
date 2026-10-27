// Off the web there is no browser console to keep: the same test files can
// run on native devices, where flutter test prints the app's output.

void installConsoleCapture() {}

void markTest(String name) {}

List<String> consoleLines() => const [];
