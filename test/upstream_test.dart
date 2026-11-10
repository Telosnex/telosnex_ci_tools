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

  group('branch', () {
    final pin = 'a' * 40;
    Map<String, Object?> commit(String c, String day) => {
      'sha': c * 40,
      'commit': {
        'committer': {'date': '2026-11-${day}T12:00:00Z'},
        'message': 'commit $c\nbody',
      },
    };
    // Five commits after the pin, oldest first: b (Nov 1) to f (Nov 5).
    final all = [
      for (final (c, d) in [
        ('b', '01'),
        ('c', '02'),
        ('d', '03'),
        ('e', '04'),
        ('f', '05'),
      ])
        commit(c, d),
    ];
    final now = DateTime.utc(2026, 11, 10, 12);
    late List<String> requests;

    // A GitHub with the commits above on main, two per compare page, and
    // the commits of each path, newest first.
    GitHubGet github(Map<String, List<String>> byPath) => (path) async {
      requests.add(path);
      final uri = Uri.parse('https://x/$path');
      if (uri.path == '/repos/o/r') return {'default_branch': 'main'};
      if (uri.path == '/repos/o/r/compare/$pin...main') {
        final page = int.parse(uri.queryParameters['page'] ?? '1');
        return {
          'status': 'ahead',
          'ahead_by': all.length,
          'commits': all.skip((page - 1) * 2).take(2).toList(),
        };
      }
      if (uri.path == '/repos/o/r/commits') {
        expect(uri.queryParameters['sha'], 'main');
        expect(uri.queryParameters['since'], '2026-11-01T12:00:00.000Z');
        return [
          for (final c in byPath[uri.queryParameters['path']] ?? <String>[])
            {'sha': c * 40},
        ];
      }
      return null;
    };
    setUp(() => requests = []);

    BranchSource source({List<String> paths = const [], int lag = 0}) =>
        BranchSource('o/r', repo: 'o/r', pin: pin, lagDays: lag, paths: paths);

    test('every page of new commits counts', () async {
      final r = await checkBranch(source(), github({}), now: now);
      expect(r.status, UpstreamStatus.update);
      expect(
        r.summary,
        'Pinned aaaaaaaaaa; main is 5 commit(s) ahead, the oldest 9 day(s) '
        'old.',
      );
      expect(r.detail.split('\n').first, 'ffffffffff 2026-11-05 commit f');
    });

    test('paths: only the commits that change them', () async {
      final r = await checkBranch(
        source(paths: ['pkg/a', 'pkg/b']),
        github({
          'pkg/a': ['d', 'b', '9'], // 9: before the pin
          'pkg/b': ['d'],
        }),
        now: now,
      );
      expect(r.status, UpstreamStatus.update);
      expect(
        r.summary,
        'Pinned aaaaaaaaaa, in 2 path(s); main is 2 commit(s) ahead, the '
        'oldest 9 day(s) old.',
      );
      expect(
        r.detail,
        'dddddddddd 2026-11-03 commit d\n'
        'bbbbbbbbbb 2026-11-01 commit b',
      );
      expect(
        upstreamNote('o/r: update', r.summary),
        'o/r: 2 commits behind main, the oldest 9 days old',
      );
    });

    test('paths: lag_days starts at the oldest commit that counts', () async {
      final r = await checkBranch(
        source(paths: ['pkg/a'], lag: 7),
        github({
          'pkg/a': ['e'],
        }),
        now: now,
      );
      expect(r.status, UpstreamStatus.upToDate);
      expect(r.summary, contains('the oldest 6 day(s) old (alert after 7)'));
    });

    test('paths: nothing new there is up to date', () async {
      final r = await checkBranch(
        source(paths: ['pkg/c']),
        github({}),
        now: now,
      );
      expect(r.status, UpstreamStatus.upToDate);
      expect(
        r.summary,
        'Pinned aaaaaaaaaa, in 1 path(s); main has nothing newer there '
        '(5 commit(s) elsewhere).',
      );
    });

    test('a pin that is not in the repository is an error', () async {
      final r = await checkBranch(
        BranchSource('o/r', repo: 'o/r', pin: 'f' * 40),
        github({}),
        now: now,
      );
      expect(r.status, UpstreamStatus.error);
    });

    test('parse: paths', () {
      final b =
          parse('''
sources:
  - name: B
    branch: https://github.com/o/b
    pin: '$pin'
    paths: [packages/a/, packages/b]
''').single
              as BranchSource;
      expect(b.paths, ['packages/a', 'packages/b']);
      for (final bad in ['[]', '[/abs]', '[a/../b]', 'packages/a', '[1]']) {
        expect(
          () => parse(
            'sources:\n  - name: B\n    branch: https://github.com/o/b\n'
            "    pin: '$pin'\n    paths: $bad\n",
          ),
          throwsA(isA<UpstreamException>()),
          reason: bad,
        );
      }
    });
  });

  test('run: exit 0 is up to date, 1 an update, others an error', () async {
    Future<UpstreamStatus> run(String c) async =>
        (await checkRun(RunSource('R', c), root.path)).status;
    expect(await run('true'), UpstreamStatus.upToDate);
    expect(await run('echo new; exit 1'), UpstreamStatus.update);
    expect(await run('exit 3'), UpstreamStatus.error);
  });
}
