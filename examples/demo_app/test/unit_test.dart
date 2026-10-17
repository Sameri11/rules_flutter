import 'package:flutter_test/flutter_test.dart';
import 'package:mylib/mylib.dart';

void main() {
  test('greeting comes from the path dependency', () {
    expect(greeting(), 'hello from mylib v3');
  });
}
