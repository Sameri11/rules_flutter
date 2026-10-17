import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('forever', () {
    print('READY');
    return Completer<void>().future;
  });
}
