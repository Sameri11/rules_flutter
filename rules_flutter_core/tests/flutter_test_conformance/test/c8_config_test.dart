import 'package:flutter_test/flutter_test.dart';
import 'flutter_test_config.dart' show configWasRun;

void main() {
  test('testExecutable wrapper', () {
    expect(configWasRun, isTrue);
  });
}
