import 'package:flutter_test/flutter_test.dart';

import '../support/marker.dart';

void main() {
  test('a nested flutter_test_config does not reach a sibling directory', () {
    expect(nestedConfigRan, isFalse);
  });
}
