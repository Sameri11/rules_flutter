@OnPlatform({'vm': Skip('vm skipped')})
library;

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('first', () => fail('body must not run'));
  test('second', () => fail('body must not run'));
}
