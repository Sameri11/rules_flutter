import 'package:flutter_test/flutter_test.dart';

import '../support/marker.dart';
import '../support/only_inside.dart';

void main() {
  test('a nested flutter_test_config applies below its directory', () {
    expect(nestedConfigRan, isTrue);
    expect(insideHelper, 'inside');
  });
}
