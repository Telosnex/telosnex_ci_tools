// The page keeps its console in globalThis.__telosnexWebTest:
//
//   lines:   '<ms since capture> <level> <text>', at most [maxConsoleLines];
//            the oldest go first.
//   dropped: how many lines went that way. Line n (from 0, ever) is
//            lines[n - dropped], so the driver's position survives the drops.
//   test:    the name of the running test.
//
// The driver reads it with [pollConsoleScript]. Both sides use this file, so
// they cannot disagree on the format.

/// The global object of the console capture.
const consoleGlobal = '__telosnexWebTest';

/// The page keeps at most this many lines.
const maxConsoleLines = 20000;

/// A longer line is cut to this many characters.
const maxConsoleLineLength = 2000;

/// The most lines one poll returns.
const maxPollLines = 5000;

/// The prefix of the console line that starts each test.
const testMarker = '==== test ';

/// Wraps console.debug/log/info/warn/error, window errors and unhandled
/// rejections. Running it again does nothing.
const installConsoleScript =
    '''
(() => {
  if (globalThis.$consoleGlobal) return;
  const state = { lines: [], dropped: 0, test: '' };
  globalThis.$consoleGlobal = state;
  const start = performance.now();
  const text = (x) => {
    if (typeof x === 'string') return x;
    if (x instanceof Error) return x.stack || String(x);
    try { return JSON.stringify(x); } catch (_) { return String(x); }
  };
  const add = (level, args) => {
    try {
      const line = args.map(text).join(' ');
      state.lines.push(Math.round(performance.now() - start) + ' ' + level +
          ' ' + line.slice(0, $maxConsoleLineLength));
      const over = state.lines.length - $maxConsoleLines;
      if (over > 0) {
        state.lines.splice(0, over);
        state.dropped += over;
      }
    } catch (_) {}
  };
  for (const level of ['debug', 'log', 'info', 'warn', 'error']) {
    const original = console[level].bind(console);
    console[level] = (...args) => { add(level, args); original(...args); };
  }
  addEventListener('error', (e) =>
      add('window.error', [e.error || e.message]));
  addEventListener('unhandledrejection',
      (e) => add('unhandledrejection', [e.reason]));
})()
''';

/// The driver's poll, run with WebDriver's execute: `arguments[0]` is the
/// number of the first line it has not read. Returns JSON:
///
///   installed: false when the page has no capture; otherwise
///   test, total (lines ever), last (the newest line, cut),
///   lost (lines dropped before they were read), next (the number after the
///   last returned line) and added (the lines).
const pollConsoleScript =
    '''
const from = arguments[0];
const state = globalThis.$consoleGlobal;
if (!state) return JSON.stringify({ installed: false });
const start = Math.max(0, from - state.dropped);
const added = state.lines.slice(start, start + $maxPollLines);
const lines = state.lines;
return JSON.stringify({
  installed: true,
  test: state.test,
  total: state.dropped + lines.length,
  last: lines.length ? lines[lines.length - 1].slice(0, 160) : '',
  lost: Math.max(0, state.dropped - from),
  next: state.dropped + start + added.length,
  added,
});
''';
