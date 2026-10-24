import 'dart:io';

import 'package:args/args.dart';
import 'package:telosnex_ci_tools/src/pin_self.dart';

/// dart run telosnex_ci_tools:pin_self [--check]
///
/// The reusable workflows of this repository use its composite actions. A
/// `uses:` cannot contain an expression, so each reference names a commit.
/// This command sets every reference to HEAD. Commit the result.
///
/// --check fails if the references name different commits, or if the
/// actions changed after the commit that they name.
Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addFlag('check', negatable: false)
    ..addFlag('help', abbr: 'h', negatable: false);
  final args = parser.parse(arguments);
  if (args.flag('help')) {
    stdout
      ..writeln('dart run telosnex_ci_tools:pin_self [--check]')
      ..writeln(parser.usage);
    return;
  }
  final root = Directory.current.path;
  try {
    if (args.flag('check')) {
      final sha = await checkSelfPins(root);
      stdout.writeln('The actions at $sha are the actions at HEAD.');
    } else {
      final (:sha, :changed) = await pinSelf(root);
      stdout.writeln(
        changed.isEmpty
            ? 'Every reference is at $sha.'
            : 'Set ${changed.join(', ')} to $sha. Commit these files.',
      );
    }
  } on PinException catch (e) {
    stderr.writeln(e.message);
    exitCode = 1;
  }
}
