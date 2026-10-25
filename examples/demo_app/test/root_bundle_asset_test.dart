import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('declared rootBundle asset can be loaded', (tester) async {
    expect((await rootBundle.loadString('assets/images/logo.txt')).trim(), 'hello-asset-one');
  });
}
