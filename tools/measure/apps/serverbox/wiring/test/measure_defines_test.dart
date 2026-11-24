import 'package:flutter_test/flutter_test.dart';

void main() {
  test('dart define is compiled in', () {
    expect(const String.fromEnvironment('MEASURE_DEFINE'), 'on');
  });
}
