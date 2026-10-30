# Flutter patches

`actions/setup-flutter` applies every `*.patch` here to the Flutter clone, in
name order, before the first `flutter` command. Keep each patch small, say
which upstream bug it fixes, and drop it once a Flutter release has the fix.

- `ios-simulator-wait-for-log-stream.patch`: `flutter test`/`run` on an iOS
  simulator launched the app before `log stream` was connected, so it could
  miss "Dart VM service is listening" and wait forever. The tool now waits
  (up to 10 s) for `log stream`'s "Filtering the log data" header first.
