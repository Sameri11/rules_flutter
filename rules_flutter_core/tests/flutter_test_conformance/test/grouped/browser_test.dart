@TestOn('browser')
library;

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('incompatible platform is skipped', () => fail('must not run on vm'));
}
