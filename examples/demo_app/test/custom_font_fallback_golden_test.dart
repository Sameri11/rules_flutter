import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('font fallback without bundle renders into a golden', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Center(
        child: Text(
          'Bazel host assets',
          style: TextStyle(fontFamily: 'ExperimentRoboto', fontSize: 24),
        ),
      ),
    ));
    final platform = Platform.isMacOS ? 'macos' : 'linux';
    await expectLater(find.byType(Text), matchesGoldenFile('goldens/custom_font_fallback_$platform.png'));
  });
}
