@Timeout(Duration(seconds: 1))
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('fast', () {});
  test('slow', () => Future<void>.delayed(const Duration(seconds: 3)));
}
