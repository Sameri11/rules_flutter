import 'package:flutter_test/flutter_test.dart';

var attempts = 0;
void main() {
  test('flaky retry', () {
    attempts++;
    print('C12 attempt $attempts');
    expect(attempts, greaterThan(1));
  }, retry: 2);
}
