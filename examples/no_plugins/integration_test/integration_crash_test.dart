import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('crashes while running case', (tester) async {
    await Future<void>.delayed(const Duration(seconds: 1));
    exit(1);
  });
}
