import 'package:flutter_test/flutter_test.dart';

void main() {
  test('timezone is UTC', () {
    expect(DateTime.now().timeZoneName, 'UTC');
    expect(DateTime.now().timeZoneOffset, Duration.zero);
  });
}
