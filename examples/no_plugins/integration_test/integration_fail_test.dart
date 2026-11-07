import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('reports a failing expectation', () {
    expect(1, 2, reason: 'intentional integration-test failure');
  });
}
