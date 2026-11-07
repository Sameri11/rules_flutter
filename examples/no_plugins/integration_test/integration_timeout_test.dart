import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'exceeds its Dart timeout',
    (tester) async => Completer<void>().future,
    timeout: const Timeout(Duration(seconds: 2)),
  );
}
