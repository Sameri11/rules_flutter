import 'dart:async';
import 'package:flutter_test/flutter_test.dart';

@Timeout(Duration(seconds: 2))
void main() {
  test(
    'explicit timeout',
    () => Completer<void>().future,
    timeout: Timeout(Duration(seconds: 1)),
  );
  test('default timeout documented', () => expect(true, isTrue));
}
