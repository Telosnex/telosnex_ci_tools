import 'dart:math' as math;

import 'job_names.dart';

/// One package in status/packages.yaml.
final class DashboardPackage {
  const DashboardPackage({
    required this.repo,
    this.tests = const ['unit.yml', 'integration.yml'],
    this.checks = const ['kiln_check.yml'],
    this.releases = const ['kiln_release.yml'],
  });

  /// owner/name.
  final String repo;
  String get name => repo.split('/').last;

  /// Workflow files whose jobs are the test cells, on the default branch.
  final List<String> tests;

  /// Other workflow files on the default branch: a status, no cells.
  final List<String> checks;

  /// Release workflow files: their newest run on any branch.
  final List<String> releases;

  /// This package without the check [file].
  DashboardPackage withoutCheck(String file) => DashboardPackage(
    repo: repo,
    tests: tests,
    checks: [
      for (final c in checks)
        if (c != file) c,
    ],
    releases: releases,
  );
}

/// A finished job of a run, as the dashboard keeps it.
final class DashboardJob {
  const DashboardJob({
    required this.name,
    required this.conclusion,
    required this.url,
  });

  final String name;

  /// success, failure, cancelled, skipped, timed_out, action_required,
  /// neutral, or null while the job runs.
  final String? conclusion;
  final String url;

  Map<String, Object?> toJson() => {
    'name': name,
    'conclusion': conclusion,
    'url': url,
    if (parseJobName(name) case final cell?) ...{
      'platform': cell.platform,
      'arch': cell.arch,
      'browser': ?cell.browser,
      'detail': ?cell.detail,
    },
  };
}

/// The newest finished run of a workflow, with its jobs.
final class DashboardRun {
  const DashboardRun({
    required this.workflowFile,
    required this.workflowName,
    required this.branch,
    required this.sha,
    required this.event,
    required this.conclusion,
    required this.url,
    required this.finishedAt,
    required this.jobs,
    this.setupJobs = const {},
    this.notes = const [],
  });

  final String workflowFile;
  final String workflowName;
  final String branch;
  final String sha;
  final String event;
  final String? conclusion;
  final String url;
  final DateTime finishedAt;
  final List<DashboardJob> jobs;

  /// Names of the jobs that other jobs of the workflow need (`needs:`):
  /// setup such as building web files or fetching models, not tests.
  final Set<String> setupJobs;

  /// What a failed run found, from its annotations: for the upstream watch,
  /// one line per update, such as `FFmpeg 9.0 → 9.0.2`.
  final List<String> notes;

  /// This run with [notes].
  DashboardRun withNotes(List<String> notes) => DashboardRun(
    workflowFile: workflowFile,
    workflowName: workflowName,
    branch: branch,
    sha: sha,
    event: event,
    conclusion: conclusion,
    url: url,
    finishedAt: finishedAt,
    jobs: jobs,
    setupJobs: setupJobs,
    notes: notes,
  );

  Map<String, Object?> toJson() => {
    'workflow': workflowFile,
    'name': workflowName,
    'branch': branch,
    'sha': sha,
    'event': event,
    'conclusion': conclusion,
    'url': url,
    'finishedAt': finishedAt.toUtc().toIso8601String(),
    'jobs': [
      for (final job in jobs)
        {...job.toJson(), if (setupJobs.contains(job.name)) 'setup': true},
    ],
    if (notes.isNotEmpty) 'notes': notes,
  };
}

/// What the dashboard found for one package.
final class PackageStatus {
  const PackageStatus(
    this.package,
    this.defaultBranch,
    this.runs, {
    this.error,
    this.usesKiln = false,
    this.usesCiTools = false,
  });

  /// Whether the default branch has kiln in its pubspec.
  final bool usesKiln;

  /// Whether a workflow of the default branch uses telosnex_ci_tools.
  final bool usesCiTools;

  bool get adopted => usesKiln || usesCiTools;

  final DashboardPackage package;
  final String defaultBranch;

  /// By workflow file. Missing: the workflow has no finished run.
  final Map<String, DashboardRun> runs;

  /// Why the package could not be read, or null.
  final String? error;

  Iterable<DashboardRun> get _tests =>
      package.tests.map((file) => runs[file]).nonNulls;

  /// The jobs of the test workflows that name a cell.
  List<(JobCell, DashboardJob)> get cellJobs => [
    for (final run in _tests)
      for (final job in run.jobs)
        if (parseJobName(job.name) case final cell?) (cell, job),
  ];

  /// The unit workflow's run: the first of [DashboardPackage.tests].
  DashboardRun? get _unit =>
      package.tests.isEmpty ? null : runs[package.tests.first];

  /// The Unit column: the unit workflow's jobs that name no cell. `Unit` in
  /// the standard workflow; `Analyze`, `Rustfmt`, `Rust (ubuntu-latest,
  /// stable)` in others.
  List<DashboardJob> get unitJobs => [
    for (final job in _unit?.jobs ?? const <DashboardJob>[])
      if (parseJobName(job.name) == null) job,
  ];

  /// The other jobs of the test workflows that name no cell: names that
  /// break the form, and setup jobs (Web files, Models) that did not pass.
  /// A setup job that passed is not shown: the jobs that need it are.
  List<DashboardJob> get otherJobs => [
    for (final run in _tests)
      if (run != _unit)
        for (final job in run.jobs)
          if (parseJobName(job.name) == null &&
              !(run.setupJobs.contains(job.name) &&
                  (job.conclusion == 'success' || job.conclusion == 'skipped')))
            job,
  ];

  Map<String, Object?> toJson() => {
    'repo': package.repo,
    'defaultBranch': defaultBranch,
    'usesKiln': usesKiln,
    'usesCiTools': usesCiTools,
    'error': ?error,
    'runs': [for (final run in runs.values) run.toJson()],
  };
}

/// The mark of a conclusion.
String mark(String? conclusion) => switch (conclusion) {
  'success' => '✅',
  'failure' || 'timed_out' || 'startup_failure' => '❌',
  'cancelled' => '🚫',
  'skipped' => '⏭️',
  null => '⏳',
  _ => '⚠️',
};

DashboardJob? _firstFailed(DashboardRun run) {
  for (final job in run.jobs) {
    if (job.conclusion == 'failure') return job;
  }
  return null;
}

/// The mark of a run. A run that failed only because GitHub cancelled
/// jobs (often when no runner took them) is 🚫, not ❌.
String runMark(DashboardRun run) {
  final m = mark(run.conclusion);
  if (m != '❌' || run.jobs.isEmpty) return m;
  final jobs = run.jobs.map((j) => mark(j.conclusion));
  if (jobs.contains('❌') || !jobs.contains('🚫')) return m;
  return '🚫';
}

String _age(DateTime at, DateTime now) {
  final d = now.difference(at);
  if (d.inMinutes < 60) return '${d.inMinutes}m';
  if (d.inHours < 48) return '${d.inHours}h';
  return '${d.inDays}d';
}

String _escape(String text) => text.replaceAll('|', r'\|').replaceAll('"', "'");

/// A linked mark with the job name as its tooltip.
String _link(DashboardJob job, [String? label]) =>
    '[${mark(job.conclusion)}${label == null ? '' : ' $label'}](${job.url} '
    '"${_escape(job.name)}")';

/// A check or release workflow's cell: its newest run, labelled with the
/// workflow's name, or [file] and `no run` when none has finished.
String _otherRunCell(
  DashboardRun? run,
  String file,
  DateTime now, {
  bool showBranch = false,
}) {
  if (run == null) return '$file: no run';
  final branch = showBranch ? ' `${run.branch}`' : '';
  return '[${runMark(run)} ${_escape(run.workflowName)}](${run.url} '
      '"${_escape(file)}") ${_age(run.finishedAt, now)}$branch';
}

/// [now] in Pacific time (PDT or PST, whichever is in force) and UTC:
/// `2026-10-29 03:11 PDT (10:11 UTC)`.
String updatedAt(DateTime now) {
  final utc = now.toUtc();
  // US daylight time: from 2:00 PST on the second Sunday of March to 2:00
  // PDT (9:00 UTC) on the first Sunday of November.
  DateTime sunday(int month, int nth) {
    final first = DateTime.utc(utc.year, month);
    return first.add(Duration(days: (7 - first.weekday) % 7 + 7 * (nth - 1)));
  }

  final start = sunday(3, 2).add(const Duration(hours: 10));
  final end = sunday(11, 1).add(const Duration(hours: 9));
  final daylight = !utc.isBefore(start) && utc.isBefore(end);
  final local = utc.subtract(Duration(hours: daylight ? 7 : 8));
  String hm(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  final date = local.toIso8601String().substring(0, 10);
  return '$date ${hm(local)} ${daylight ? 'PDT' : 'PST'} (${hm(utc)} UTC)';
}

/// The dashboard: every test cell, then failing and cancelled runs.
String renderDashboard(List<PackageStatus> unsorted, DateTime now) {
  // Alphabetical, ignoring case, in every section.
  final packages = [...unsorted]
    ..sort(
      (a, b) =>
          a.package.name.toLowerCase().compareTo(b.package.name.toLowerCase()),
    );
  final out = StringBuffer()
    ..writeln('# Telosnex CI dashboard')
    ..writeln()
    ..writeln(
      '${packages.length} packages maintained by Telosnex for the Telosnex '
      'app.',
    )
    ..writeln()
    ..writeln('Updated ${updatedAt(now)}.')
    ..writeln()
    ..writeln(
      'GitHub runs the refresh a few times a day, not every 30 min as '
      'scheduled. To refresh now, run the '
      '[Dashboard workflow](https://github.com/Telosnex/telosnex_ci_tools/actions/workflows/dashboard.yml).',
    )
    ..writeln()
    ..writeln(
      '✅ passed · ❌ failed · 🚫 cancelled · ⏭️ skipped · ⏳ running · '
      '⚠️ other · — none (no such job or workflow) · no run: a workflow '
      'with no finished run yet',
    )
    ..writeln();

  final ordered = {
    for (final status in packages)
      for (final (cell, _) in status.cellJobs)
        if (cell.isNormal) cell.column,
  }.toList()..sort(JobCell.compareColumns);
  // An extra target (`Linux x64 fake camera`) goes in the column its name
  // starts with, after the usual job, when some package has that column.
  final known = ordered.toSet();
  bool inColumn(JobCell cell) => cell.isNormal || known.contains(cell.column);
  // Every other job (an extra target with no such column, or a name with no
  // platform outside the unit workflow) has a cell of its own, labelled with
  // its name. As many blank-headed columns as the package with most, so no
  // package's job names add columns for every other package.
  // The check and release workflows follow, one cell each, labelled with
  // the workflow's name and its age; a release also with its branch.
  List<String> extras(PackageStatus status) => [
    ...([
      for (final (cell, job) in status.cellJobs)
        if (!inColumn(cell)) job,
    ]..sort((a, b) => a.name.compareTo(b.name))).map((j) => _link(j, j.name)),
    ...status.otherJobs.map((j) => _link(j, j.name)),
    for (final file in status.package.checks)
      _otherRunCell(status.runs[file], file, now),
    for (final file in status.package.releases)
      _otherRunCell(status.runs[file], file, now, showBranch: true),
  ];
  final extraColumns = packages.fold(
    0,
    (most, status) => math.max(most, extras(status).length),
  );
  out
    ..writeln()
    ..writeln('## Test cells')
    ..writeln()
    ..writeln(
      'The jobs of the test workflows, by the platform in their name. A web '
      'column holds every host and compiler: the tooltip says which. An extra '
      'target (a detail in the name, such as `Linux x64 fake camera`) is one '
      'more mark in its platform column, after the usual job. The unnamed '
      'columns hold every other job of a package, one each, labelled with '
      'its name: extra targets with no such column, and names with no '
      'platform, then the check and release workflows (such as the upstream '
      'watch and Kiln release), with how long ago their newest run finished. '
      'Unit holds the jobs of the unit workflow that name no platform.',
    )
    ..writeln()
    ..writeln(
      '| Package | Unit | '
      '${[...ordered, ...List.filled(extraColumns, ' ')].join(' | ')} |',
    )
    ..writeln('|---|---|${'---|' * (ordered.length + extraColumns)}');
  for (final status in packages) {
    final byColumn = <String, List<(JobCell, DashboardJob)>>{};
    for (final entry in status.cellJobs) {
      if (inColumn(entry.$1)) (byColumn[entry.$1.column] ??= []).add(entry);
    }
    final extra = extras(status);
    final name = status.error == null
        ? status.package.name
        : '${status.package.name} ⚠️ ${_escape(status.error!)}';
    final unit = status.unitJobs;
    final cells = [
      unit.isEmpty ? '—' : unit.map(_link).join(' '),
      for (final column in ordered)
        byColumn[column] == null
            ? '—'
            // The usual jobs first, then extra targets; each by name.
            : (byColumn[column]!..sort(
                    (a, b) => a.$1.isNormal != b.$1.isNormal
                        ? (a.$1.isNormal ? -1 : 1)
                        : a.$2.name.compareTo(b.$2.name),
                  ))
                  .map((e) => _link(e.$2))
                  .join(' '),
      for (var i = 0; i < extraColumns; i++) i < extra.length ? extra[i] : '',
    ];
    out.writeln(
      '| [$name](https://github.com/${status.package.repo}) | '
      '${cells.join(' | ')} |',
    );
  }

  // Failing: runs where a job failed. Cancelled: failed runs where no job
  // failed but GitHub cancelled some, often because no runner took them.
  // Apart, so that real failures do not hide among many cancellations.
  final failing = <(String, DashboardRun, String)>[];
  final cancelledRuns = <(String, DashboardRun, String)>[];
  for (final status in packages) {
    for (final run in status.runs.values) {
      String links(String conclusion) => [
        for (final job in run.jobs)
          if (job.conclusion == conclusion) '[${job.name}](${job.url})',
      ].join(', ');
      final failed = links('failure');
      final cancelled = run.jobs.where((j) => j.conclusion == 'cancelled');
      final runFailed = mark(run.conclusion) == '❌';
      if (runMark(run) == '🚫') {
        cancelledRuns.add((status.package.name, run, links('cancelled')));
      } else if (failed.isNotEmpty || runFailed) {
        failing.add((
          status.package.name,
          run,
          [
            if (run.notes.isNotEmpty)
              '[${run.notes.join(', ')}](${_firstFailed(run)?.url ?? run.url})'
            else if (failed.isNotEmpty)
              failed
            else
              '[run](${run.url})',
            if (cancelled.isNotEmpty) '${cancelled.length} cancelled',
          ].join(' · '),
        ));
      }
    }
  }
  void section(
    String title,
    String? note,
    List<(String, DashboardRun, String)> rows,
  ) {
    if (rows.isEmpty) return;
    out
      ..writeln()
      ..writeln('## $title')
      ..writeln();
    if (note != null) {
      out
        ..writeln(note)
        ..writeln();
    }
    for (final (name, run, what) in rows) {
      out.writeln(
        '- **$name** · ${run.workflowName} · $what · '
        '${_age(run.finishedAt, now)} ago, `${run.branch}` '
        '`${run.sha.isEmpty ? '' : run.sha.substring(0, 7)}`',
      );
    }
  }

  section('Failing', null, failing);
  section(
    'Cancelled',
    'No job failed, but GitHub cancelled these, often because no runner '
        'took them. Re-run them.',
    cancelledRuns,
  );
  return out.toString();
}

/// The live dashboard.
const dashboardUrl =
    'https://github.com/Telosnex/telosnex_ci_tools/tree/dashboard';

/// status/packages.md: the packages that use Kiln or CI tools on their
/// default branch. No time in it: it changes only when a package does.
String renderPackages(List<PackageStatus> packages) {
  final sorted = [...packages]
    ..sort((a, b) => a.package.name.compareTo(b.package.name));
  String yes(bool value) => value ? '✅' : '—';
  final out = StringBuffer()
    ..writeln('# Packages')
    ..writeln()
    ..writeln(
      'The Telosnex repositories that use Kiln or telosnex_ci_tools on their '
      'default branch. Generated from `status/packages.yaml` by the Dashboard '
      'workflow; do not edit. Their CI: the [dashboard]($dashboardUrl).',
    )
    ..writeln()
    ..writeln('| Name | Uses Kiln | Uses CI tools |')
    ..writeln('|---|---|---|');
  for (final status in sorted.where((s) => s.adopted)) {
    final repo = status.package.repo;
    out.writeln(
      '| [${status.package.name}](https://github.com/$repo) | '
      '${yes(status.usesKiln)} | ${yes(status.usesCiTools)} |',
    );
  }
  final pending = sorted.where((s) => !s.adopted).toList();
  if (pending.isNotEmpty) {
    out
      ..writeln()
      ..writeln(
        'Not on the default branch yet: '
        '${pending.map((s) => '[${s.package.name}](https://github.com/${s.package.repo})').join(', ')}.',
      );
  }
  return out.toString();
}
