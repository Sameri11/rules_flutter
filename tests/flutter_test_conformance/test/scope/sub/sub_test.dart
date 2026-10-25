import 'package:flutter_test/flutter_test.dart';

import 'marker.dart';

void main() {
  test('a subpackage flutter_test_config applies to its own tests', () {
    expect(subConfigRan, isTrue);
  });
}
