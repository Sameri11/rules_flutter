@ft.Skip('prefixed skip')
library;

import 'package:flutter_test/flutter_test.dart' as ft;

void main() {
  ft.test('body', () => throw StateError('body must not run'));
}
