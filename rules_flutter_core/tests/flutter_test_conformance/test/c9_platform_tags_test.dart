import 'package:flutter_test/flutter_test.dart';

void main() {
  test('browser-only', () {}, testOn: 'browser');
  test('tagged test', () {}, tags: ['conformance-tag']);
}
