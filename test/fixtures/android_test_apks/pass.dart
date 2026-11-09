// A fixture of actions/android-test-apks and actions/android-arm64-container
// (ci.yml): passes on arm64 Android.
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a tap counts', (tester) async {
    var count = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) => Scaffold(
            body: Center(child: Text('count $count')),
            floatingActionButton: FloatingActionButton(
              onPressed: () => setState(() => count++),
              child: const Icon(Icons.add),
            ),
          ),
        ),
      ),
    );
    // The container's screen is on and unlocked: the view has its size.
    expect(tester.view.physicalSize.isEmpty, isFalse);
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    expect(find.text('count 1'), findsOneWidget);
    await binding.convertFlutterSurfaceToImage();
    await tester.pumpAndSettle();
    expect(await binding.takeScreenshot('count'), isNotEmpty);
  });

  test('native code is arm64', () {
    final getpid = DynamicLibrary.process()
        .lookupFunction<Int32 Function(), int Function()>('getpid');
    expect(getpid(), pid);
    expect(Abi.current(), Abi.androidArm64);
  });
}
