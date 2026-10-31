// @Skip('in a comment') would skip every case.
/* @Timeout(Duration(seconds: 1)) @Tags(['slow']) */
import 'package:flutter_test/flutter_test.dart';

const note = "@Skip('in a string') @TestOn('browser') @Retry(5)";

void main() {
  test('runs', () {
    expect(note, contains('@Skip'));
  });
}
