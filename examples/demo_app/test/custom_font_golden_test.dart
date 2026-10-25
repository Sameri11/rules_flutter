import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('pubspec custom font renders into a golden', (tester) async {
    final fontLoader = FontLoader('ExperimentRoboto')
      ..addFont(rootBundle.load('assets/fonts/ExperimentRoboto-Regular.ttf'));
    await fontLoader.load();
    await tester.pumpWidget(const MaterialApp(
      home: Center(
        child: Text(
          'Bazel host assets',
          style: TextStyle(fontFamily: 'ExperimentRoboto', fontSize: 24),
        ),
      ),
    ));
    final platform = Platform.isMacOS ? 'macos' : 'linux';
    await expectLater(find.byType(Text), matchesGoldenFile('goldens/custom_font_$platform.png'));
  });
}
