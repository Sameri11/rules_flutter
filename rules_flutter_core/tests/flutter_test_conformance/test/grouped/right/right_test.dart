@Tags(<String>['grouped-right'])
@Timeout(Duration(seconds: 20))
@TestOn('vm')
library;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../grouped_shared.dart';

void main() {
  testWidgets('right golden is file-relative', (tester) async {
    await tester.pumpWidget(const ColoredBox(color: Colors.blue));
    await expectLater(find.byType(ColoredBox), matchesGoldenFile('goldens/right.png'));
  });

  test('group-only state leaks from left file', () {
      final filtered = (Platform.environment['TESTBRIDGE_TEST_ONLY'] ?? '').isNotEmpty;
      expect(state, contains('right-config-before'));
      if (filtered) {
        expect(state, isNot(contains('left-setUpAll')));
      } else {
        expect(state, contains('left-config-before'));
        expect(state, contains('left-setUpAll'));
        expect(identical(savedBinding, TestWidgetsFlutterBinding.instance), isTrue);
        expect(leakedTimer, isNotNull);
        expect(leakedTimer!.isActive, isFalse);
      }
      expect(debugDefaultTargetPlatformOverride, isNull);
      expect(HttpOverrides.current, isNot(isA<FixtureHttpOverrides>()));
  });

  test('intentional failure remains visible', () => expect(1, 2));
}
