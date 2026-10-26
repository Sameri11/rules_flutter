import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('app assets load through the root bundle', (tester) async {
    expect(
      (await rootBundle.loadString('assets/images/logo.txt')).trim(),
      'hello-asset-one',
    );
    expect(
      (await rootBundle.load('assets/images/pixel.bin')).lengthInBytes,
      1,
    );
  });

  testWidgets('framework shaders load through the root bundle', (tester) async {
    expect(
      (await rootBundle.load('shaders/ink_sparkle.frag')).lengthInBytes,
      greaterThan(0),
    );
  });
}
