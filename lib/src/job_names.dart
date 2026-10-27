/// The Telosnex job name form (README, "Job names"):
/// `<Platform> <Arch> [detail]` (`Windows ARM64`, `iOS ARM64 simulator`) and
/// `Web <Platform> <Arch> <Browser> [detail]` (`Web Linux x64 Chrome
/// dart2wasm`). The lint checks names against it, and the dashboard reads
/// its cells from it.
library;

const platforms = ['Linux', 'macOS', 'Windows', 'iOS', 'Android'];
const archs = ['x64', 'ARM64', 'ARM', 'x86', 'universal'];
const browsers = ['Chrome', 'Firefox', 'Safari', 'Edge'];

final nativeJobName = RegExp(
  '^(${platforms.join('|')}) (${archs.join('|')})(?: (\\S.*))?\$',
);
final webJobName = RegExp(
  '^Web (${platforms.join('|')}) (${archs.join('|')}) '
  '(${browsers.join('|')})(?: (\\S.*))?\$',
);

/// What a job name in the Telosnex form says.
final class JobCell {
  const JobCell({
    required this.platform,
    required this.arch,
    this.browser,
    this.detail,
  });

  final String platform;
  final String arch;

  /// Null for a job that is not a web job.
  final String? browser;
  final String? detail;

  bool get isWeb => browser != null;

  /// The dashboard column: `Linux x64`, or `Web Chrome` (the host platform
  /// and the detail tell the jobs of one column apart).
  String get column => isWeb ? 'Web $browser' : '$platform $arch';

  /// The order of [column]s: platforms, then archs, then browsers.
  int get order => isWeb
      ? 1000 + browsers.indexOf(browser!)
      : platforms.indexOf(platform) * 10 + archs.indexOf(arch);
}

/// The cell of a job name in the Telosnex form, or null.
JobCell? parseJobName(String name) {
  final web = webJobName.firstMatch(name);
  if (web != null) {
    return JobCell(
      platform: web[1]!,
      arch: web[2]!,
      browser: web[3],
      detail: web[4],
    );
  }
  final native = nativeJobName.firstMatch(name);
  if (native != null) {
    return JobCell(platform: native[1]!, arch: native[2]!, detail: native[3]);
  }
  return null;
}
