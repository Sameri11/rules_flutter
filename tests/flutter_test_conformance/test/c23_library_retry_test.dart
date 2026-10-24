@Retry(2)
library;

import 'package:flutter_test/flutter_test.dart';

var attempts = 0;

void main() {
  test('flaky until the third attempt', () {
    attempts++;
    expect(attempts, 3);
  });
}
