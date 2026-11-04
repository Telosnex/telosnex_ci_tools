import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:telosnex_ci_tools/src/upstream.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  setUp(() {
    root = Directory.systemTemp.createTempSync('upstream_test');
    File(p.join(root.path, 'fetch.sh'))
      ..createSync()
      ..writeAsStringSync('x=1\nrevision=${'a' * 40}\n');
  });
  tearDown(() => root.deleteSync(recursive: true));

  List<UpstreamSource> parse(String yaml) => parseUpstream(yaml, root.path);

  group('parse', () {
    test('kinds, pins from files, defaults', () {
      final sources = parse('''
sources:
  - name: A
    tags: https://example.com/a.git
    pin: {file: fetch.sh, pattern: '^revision=([0-9a-f]{40})'}
  - name: B
    branch: https://github.com/o/b.git
    pin: '${'b' * 40}'
    lag_days: 7
  - name: C
    run: echo hi
''');
      final a = sources[0] as TagsSource;
      expect(a.pin, 'a' * 40);
      expect(a.alert, AlertLevel.minor);
      final b = sources[1] as BranchSource;
      expect(b.repo, 'o/b');
      expect(b.lagDays, 7);
      expect((sources[2] as RunSource).command, 'echo hi');
    });

    test('errors name the source', () {
      expect(
        () => parse('sources:\n  - name: X\n    tags: u\n    run: y\n'),
        throwsA(
          isA<UpstreamException>().having(
            (e) => e.message,
            'message',
            contains('X: needs exactly one'),
          ),
        ),
      );
      expect(
        () => parse(
          'sources:\n  - name: X\n    tags: u\n'
          '    pin: {file: fetch.sh, pattern: nope}\n',
        ),
        throwsA(isA<UpstreamException>()),
      );
      expect(
        () => parse(
          'sources:\n  - name: X\n    branch: https://gitlab.com/a/b\n'
          '    pin: x\n',
        ),
        throwsA(isA<UpstreamException>()),
      );
      expect(() => parse('nope: 1'), throwsA(isA<UpstreamException>()));
    });
  });

  test('versions', () {
    expect(versionParts('9.0.2'), [9, 0, 2]);
    expect(compareVersions([9, 0], [9, 0, 0]), 0);
    expect(compareVersions([9, 0, 2], [9, 0], 2), 0);
    expect(compareVersions([9, 1], [9, 0, 7], 2), 1);
  });

  test('ls-remote: annotated tags resolve to their commit', () {
    final tags = parseLsRemote(
      '${'1' * 40}\trefs/tags/v1.0.0\n'
      '${'2' * 40}\trefs/tags/v1.0.0^{}\n'
      '${'3' * 40}\trefs/tags/v1.1.0\n'
      '${'4' * 40}\trefs/heads/main\n',
    );
    expect(tags, {'v1.0.0': '2' * 40, 'v1.1.0': '3' * 40});
  });

  group('tags', () {
    final tags = {
      'v1.2.0': 'a' * 40,
      'v1.2.1': 'b' * 40,
      'v1.3.0-rc1': 'c' * 40,
      'v1.3.0': 'd' * 40,
      'v2.0.0': 'e' * 40,
      'other': 'f' * 40,
    };
    TagsSource source(
      String pin, {
      AlertLevel alert = AlertLevel.minor,
      String? seen,
    }) => TagsSource(
      'S',
      url: 'u',
      pin: pin,
      version: RegExp(r'^(?:v?(\d+(?:\.\d+)+))$'),
      alert: alert,
      seen: seen,
    );

    test('a commit pin is the version of its tag', () {
      final r = checkTags(source('a' * 40, alert: AlertLevel.major), tags);
      expect(r.status, UpstreamStatus.update);
      expect(r.detail, 'v2.0.0');
      expect(r.summary, contains('Pinned 1.2.0; newest 2.0.0'));
    });

    test('alert levels; release candidates do not count', () {
      expect(checkTags(source('1.3.0'), tags).detail, 'v2.0.0');
      expect(checkTags(source('1.2.0'), tags).detail, 'v1.3.0\nv2.0.0');
      expect(
        checkTags(source('1.2.0', alert: AlertLevel.patch), tags).detail,
        'v1.2.1\nv1.3.0\nv2.0.0',
      );
      expect(checkTags(source('2.0.0'), tags).status, UpstreamStatus.upToDate);
    });

    test('seen skips updates up to it', () {
      expect(
        checkTags(source('1.2.0', seen: '2.0'), tags).status,
        UpstreamStatus.upToDate,
      );
    });

    test('a commit that no version tag names is an error', () {
      expect(checkTags(source('f' * 40), tags).status, UpstreamStatus.error);
    });
  });

  test('upstreamNote reads the annotations of the watch', () {
    final tags = checkTags(
      TagsSource(
        'FFmpeg',
        url: 'u',
        pin: '9.0',
        version: RegExp(r'^(?:n(\d+(?:\.\d+)*))$'),
        alert: AlertLevel.patch,
      ),
      {'n9.0': 'a' * 40, 'n9.0.2': 'b' * 40},
    );
    expect(upstreamNote('FFmpeg: update', tags.summary), 'FFmpeg 9.0 → 9.0.2');
    expect(
      upstreamNote(
        'BoringSSL: update',
        'Pinned 5ee9407bc2; main is 575 commit(s) ahead, the oldest 79 '
            'day(s) old.',
      ),
      'BoringSSL: 575 commits behind main, the oldest 79 days old',
    );
    expect(
      upstreamNote('WebRTC: update', 'The command reports an update.'),
      'WebRTC: update',
    );
    expect(upstreamNote('X: error', 'boom'), 'X: error: boom');
    expect(upstreamNote('', 'Process completed with exit code 1.'), isNull);
  });

  test('run: exit 0 is up to date, 1 an update, others an error', () async {
    Future<UpstreamStatus> run(String c) async =>
        (await checkRun(RunSource('R', c), root.path)).status;
    expect(await run('true'), UpstreamStatus.upToDate);
    expect(await run('echo new; exit 1'), UpstreamStatus.update);
    expect(await run('exit 3'), UpstreamStatus.error);
  });
}
