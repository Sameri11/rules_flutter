import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

// A late test() is a load failure here; the CLI fails the running test instead.
void main() {
  test('declared in time', () {});
  Timer(Duration.zero, () => test('declared late', () {}));
}
