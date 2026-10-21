import 'package:demo_app/build_info.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('dart_defines of the test reach the app library', () {
    expect(buildFlavor, 'staging');
  });
}
