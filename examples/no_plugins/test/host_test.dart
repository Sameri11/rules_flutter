import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('host-only widget test runs without app assets', (tester) async {
    await tester.pumpWidget(const Directionality(
      textDirection: TextDirection.ltr,
      child: Center(child: Text('host-test')),
    ));
    expect(find.text('host-test'), findsOneWidget);
  });
}
