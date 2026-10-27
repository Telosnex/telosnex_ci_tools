import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'console_protocol.dart';

void _eval(String script) =>
    globalContext.callMethod<JSAny?>('eval'.toJS, script.toJS);

JSObject? get _state {
  final state = globalContext[consoleGlobal];
  return state.isA<JSObject>() ? state as JSObject : null;
}

void installConsoleCapture() => _eval(installConsoleScript);

void markTest(String name) {
  _state?['test'] = name.toJS;
  _eval('console.info(${jsonEncode('$testMarker$name')})');
}

List<String> consoleLines() {
  final lines = _state?['lines'];
  if (lines == null) return const [];
  return [for (final line in (lines as JSArray<JSString>).toDart) line.toDart];
}
