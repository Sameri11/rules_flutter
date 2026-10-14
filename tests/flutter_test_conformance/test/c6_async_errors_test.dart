import 'dart:async';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('uncaught future error before completion', () async {
    unawaited(
      Future<void>.delayed(
        Duration.zero,
        () => throw StateError('inside async error'),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
  });
  test('error after test completion', () {
    Timer.run(() => throw StateError('after completion error'));
  });
}
