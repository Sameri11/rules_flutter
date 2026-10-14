import 'dart:async';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('expectAsync1 called', () async {
    final callback = expectAsync1((int value) => expect(value, 7));
    Timer.run(() => callback(7));
  });
  test('expectAsync1 not called', () {
    expectAsync1((int value) => expect(value, 7));
  }, timeout: Timeout(Duration(seconds: 1)));
}
