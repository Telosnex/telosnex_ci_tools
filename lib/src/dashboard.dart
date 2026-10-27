import 'job_names.dart';

/// One package in dashboard.yaml.
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

  Map<String, Object?> toJson() => {
    'workflow': workflowFile,
    'name': workflowName,
    'branch': branch,
    'sha': sha,
    'event': event,
    'conclusion': conclusion,
    'url': url,
    'finishedAt': finishedAt.toUtc().toIso8601String(),
    'jobs': [for (final job in jobs) job.toJson()],
  };
}

/// What the dashboard found for one package.
final class PackageStatus {
  const PackageStatus(
    this.package,
    this.defaultBranch,
    this.runs, {
    this.error,
  });

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

  /// The jobs of the test workflows that do not: Unit, Web files, Plan, and
  /// names that break the form.
  List<DashboardJob> get otherJobs => [
    for (final run in _tests)
      for (final job in run.jobs)
        if (parseJobName(job.name) == null) job,
  ];

  Map<String, Object?> toJson() => {
    'repo': package.repo,
    'defaultBranch': defaultBranch,
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

String _runCell(DashboardRun? run, DateTime now, {bool showBranch = false}) {
  if (run == null) return '—';
  final branch = showBranch ? ' `${run.branch}`' : '';
  return '[${mark(run.conclusion)}](${run.url} "${_escape(run.workflowName)}") '
      '${_age(run.finishedAt, now)}$branch';
}

/// The dashboard: a status per workflow, then every test cell.
String renderDashboard(List<PackageStatus> packages, DateTime now) {
  final out = StringBuffer()
    ..writeln('# CI dashboard')
    ..writeln()
    ..writeln(
      'Updated ${now.toUtc().toIso8601String().substring(0, 16)}Z by '
      '`dart run telosnex_ci_tools:dashboard`. The newest finished run of '
      'each workflow on the default branch; release workflows on any branch. '
      'Hover a mark for the job, click it for the log.',
    )
    ..writeln()
    ..writeln(
      '✅ passed · ❌ failed · 🚫 cancelled · ⏭️ skipped · ⏳ running · '
      '⚠️ other · — no job',
    )
    ..writeln()
    ..writeln('## Workflows')
    ..writeln();

  final files = <String>[];
  final releases = <String>{};
  for (final status in packages) {
    final package = status.package;
    for (final file in [
      ...package.tests,
      ...package.checks,
      ...package.releases,
    ]) {
      if (!files.contains(file)) files.add(file);
    }
    releases.addAll(package.releases);
  }
  out
    ..writeln('| Package | ${files.join(' | ')} |')
    ..writeln('|---|${'---|' * files.length}');
  for (final status in packages) {
    final cells = [
      for (final file in files)
        status.package.tests.contains(file) ||
                status.package.checks.contains(file) ||
                status.package.releases.contains(file)
            ? _runCell(
                status.runs[file],
                now,
                showBranch: releases.contains(file),
              )
            : '',
    ];
    final name = status.error == null
        ? status.package.name
        : '${status.package.name} ⚠️ ${_escape(status.error!)}';
    out.writeln(
      '| [$name](https://github.com/${status.package.repo}) | '
      '${cells.join(' | ')} |',
    );
  }

  final columns = <String, int>{};
  for (final status in packages) {
    for (final (cell, _) in status.cellJobs) {
      columns[cell.column] = cell.order;
    }
  }
  final ordered = columns.keys.toList()
    ..sort((a, b) => columns[a]!.compareTo(columns[b]!));
  out
    ..writeln()
    ..writeln('## Test cells')
    ..writeln()
    ..writeln(
      'The jobs of the test workflows, by the platform in their name. A web '
      "column holds every host and compiler: the tooltip says which. Jobs "
      'whose name has no platform are under Other.',
    )
    ..writeln()
    ..writeln('| Package | ${[...ordered, 'Other'].join(' | ')} |')
    ..writeln('|---|${'---|' * (ordered.length + 1)}');
  for (final status in packages) {
    final byColumn = <String, List<(JobCell, DashboardJob)>>{};
    for (final entry in status.cellJobs) {
      (byColumn[entry.$1.column] ??= []).add(entry);
    }
    final cells = [
      for (final column in ordered)
        byColumn[column] == null
            ? '—'
            : (byColumn[column]!
                    ..sort((a, b) => a.$2.name.compareTo(b.$2.name)))
                  .map((e) => _link(e.$2))
                  .join(' '),
      status.otherJobs.isEmpty
          ? '—'
          : status.otherJobs.map((job) => _link(job, job.name)).join('<br>'),
    ];
    out.writeln('| ${status.package.name} | ${cells.join(' | ')} |');
  }

  final failing = [
    for (final status in packages)
      for (final run in status.runs.values)
        for (final job in run.jobs)
          if (mark(job.conclusion) == '❌') (status.package.name, run, job),
  ];
  if (failing.isNotEmpty) {
    out
      ..writeln()
      ..writeln('## Failing')
      ..writeln();
    for (final (name, run, job) in failing) {
      out.writeln(
        '- **$name** · ${run.workflowName} · [${job.name}](${job.url}) · '
        '${_age(run.finishedAt, now)} ago, `${run.branch}` '
        '`${run.sha.substring(0, 7)}`',
      );
    }
  }
  return out.toString();
}
