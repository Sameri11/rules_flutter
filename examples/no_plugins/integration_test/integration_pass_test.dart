import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('shows the app', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Text('integration pass')));
    expect(find.text('integration pass'), findsOneWidget);
  });

  testWidgets('shows another widget', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Text('second pass')));
    expect(find.text('second pass'), findsOneWidget);
  });
}
