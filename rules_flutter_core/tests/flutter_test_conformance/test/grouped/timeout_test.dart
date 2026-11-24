@Timeout(Duration(milliseconds: 5))
library;

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('per-file timeout is preserved', () async {
    await Future<void>.delayed(const Duration(milliseconds: 100));
  });
}
