@Skip('general reason')
@OnPlatform({'vm': Skip('VM reason')})
library;

import 'package:flutter_test/flutter_test.dart';

void main() {
  setUpAll(() => fail('setUpAll must not run'));
  test('first', () => fail('body must not run'));
  test('second', () => fail('body must not run'));
}
