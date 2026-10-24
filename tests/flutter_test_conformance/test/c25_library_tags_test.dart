@Tags(['slow', 'io'])
library;

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('tagged by library', () {});
  test('tagged by library and case', () {}, tags: ['extra']);
}
