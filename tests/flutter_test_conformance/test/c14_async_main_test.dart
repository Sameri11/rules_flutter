import 'package:flutter_test/flutter_test.dart';

// main awaits before it declares, so the listener must wait for it to finish.
Future<void> main() async {
  await Future<void>.delayed(Duration.zero);
  test('declared after an await', () {});
}
