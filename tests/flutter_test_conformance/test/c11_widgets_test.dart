import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('all target platform variants', (tester) async {
    expect(true, isTrue);
  }, variant: TargetPlatformVariant.all());
  testWidgets('pending timer at test end', (tester) async {
    Timer(const Duration(hours: 1), () {});
  });
  testWidgets('runAsync', (tester) async {
    final value = await tester.runAsync(() async => 5);
    expect(value, 5);
  });
  testWidgets('exception in build', (tester) async {
    await tester.pumpWidget(
      Builder(builder: (_) => throw StateError('C11 build exception marker')),
    );
  });
}
