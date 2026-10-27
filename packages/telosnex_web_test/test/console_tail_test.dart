@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:telosnex_web_test/src/console_tail.dart';

void main() {
  late Directory dir;
  late ConsoleTail tail;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('console_tail');
    tail = ConsoleTail(File('${dir.path}/logs/web_console.log'));
  });
  tearDown(() => dir.deleteSync(recursive: true));

  String log() => tail.file.readAsStringSync();

  test('appends each answer in order', () {
    expect(log(), '');
    expect(
      tail.apply({
        'installed': true,
        'test': 'a',
        'total': 2,
        'last': '2',
        'lost': 0,
        'next': 2,
        'added': ['1', '2'],
      }),
      isFalse,
    );
    tail.apply({
      'installed': true,
      'test': 'b',
      'total': 3,
      'last': '3',
      'lost': 0,
      'next': 3,
      'added': ['3'],
    });
    expect(log(), '1\n2\n3\n');
    expect(tail.next, 3);
    expect(tail.test, 'b');
  });

  test('says more lines wait while next < total', () {
    expect(
      tail.apply({
        'installed': true,
        'total': 9000,
        'lost': 0,
        'next': 5000,
        'added': List.filled(5000, 'x'),
      }),
      isTrue,
    );
  });

  test('notes the lines the page dropped before they were read', () {
    tail.next = 10;
    tail.apply({
      'installed': true,
      'total': 30,
      'lost': 5,
      'next': 30,
      'added': ['15'],
    });
    expect(log(), startsWith('[telosnex_web_test: the page dropped 5 '));
    expect(log(), endsWith('15\n'));
    expect(tail.next, 30);
  });

  test('a page without the capture', () {
    expect(tail.apply({'installed': false}), isFalse);
    expect(tail.installed, isFalse);
    expect(log(), '');
  });
}
