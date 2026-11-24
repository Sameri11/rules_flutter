@Tags(<String>['grouped-left'])
@Timeout(Duration(seconds: 15))
@TestOn('vm')
library;
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../grouped_shared.dart';

void main() {
  if (Platform.environment['GROUPED_EXPECT_STATE'] == '1') {
    leakedTimer = Timer(const Duration(days: 1), () {});
  }
  setUpAll(() {
    state.add('left-setUpAll');
    savedBinding = TestWidgetsFlutterBinding.ensureInitialized();
  });

  tearDownAll(() {
    if (Platform.environment['GROUPED_EXPECT_STATE'] == '1') {
      HttpOverrides.global = FixtureHttpOverrides();
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    }
  });

  testWidgets('left golden is file-relative', (tester) async {
    await tester.pumpWidget(const ColoredBox(color: Colors.red));
    await expectLater(find.byType(ColoredBox), matchesGoldenFile('goldens/left.png'));
  });

  test('left config and setUpAll ran', () {
    expect(state, contains('left-config-before'));
    expect(state, contains('left-setUpAll'));
  });
}
