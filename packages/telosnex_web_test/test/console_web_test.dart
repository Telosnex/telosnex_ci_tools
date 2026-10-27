// The console capture and the driver's poll script, in a browser:
// flutter test --platform chrome
@TestOn('browser')
library;

import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter_test/flutter_test.dart';
import 'package:telosnex_web_test/src/console_protocol.dart';
import 'package:telosnex_web_test/src/console_web.dart';

@JS('console.log')
external void _log(String message);

@JS('console.error')
external void _error(JSAny? value);

/// Runs [pollConsoleScript] as WebDriver's execute does.
Map<String, Object?> _poll(int from) {
  final function = globalContext.callMethod<JSFunction>(
    'Function'.toJS,
    pollConsoleScript.toJS,
  );
  final json = function.callAsFunction(null, from.toJS) as JSString;
  return jsonDecode(json.toDart) as Map<String, Object?>;
}

void main() {
  test('without the capture, the poll says so', () {
    expect(_poll(0), {'installed': false});
  });

  group('with the capture', () {
    setUpAll(installConsoleCapture);

    test('keeps console lines with their level', () {
      final before = _poll(0)['total']! as int;
      _log('hello');
      _error('bad'.toJS);
      markTest('my test');
      final answer = _poll(before);
      expect(answer['installed'], isTrue);
      expect(answer['test'], 'my test');
      expect(answer['next'], before + 3);
      final added = (answer['added']! as List).cast<String>();
      expect(added[0], matches(RegExp(r'^\d+ log hello$')));
      expect(added[1], matches(RegExp(r'^\d+ error bad$')));
      expect(added[2], endsWith(' info ==== test my test'));
      expect(consoleLines().sublist(before), hasLength(3));
    });

    test('installing again keeps the same lines', () {
      final before = _poll(0)['total']! as int;
      installConsoleCapture();
      expect(_poll(0)['total'], before);
    });

    test('cuts long lines', () {
      final from = _poll(0)['total']! as int;
      _log('x' * (maxConsoleLineLength + 100));
      final line = (_poll(from)['added']! as List).single as String;
      expect(line.length, lessThan(maxConsoleLineLength + 20));
    });

    test('drops the oldest lines and counts what the reader lost', () {
      final from = _poll(0)['total']! as int;
      for (var i = 0; i < maxConsoleLines + 10; i++) {
        _log('line $i');
      }
      final answer = _poll(from);
      expect(answer['total'], from + maxConsoleLines + 10);
      expect(answer['lost'], 10);
      final added = (answer['added']! as List).cast<String>();
      expect(added, hasLength(maxPollLines));
      // Line numbers stay right across the drops.
      final next = answer['next']! as int;
      final rest = _poll(next);
      expect(rest['lost'], 0);
      expect((rest['added']! as List).first, endsWith('line ${next - from}'));
      expect(consoleLines(), hasLength(maxConsoleLines));
    });
  });
}
