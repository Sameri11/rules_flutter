import 'package:flutter_test/flutter_test.dart';

void main() {
  group(
    'outer',
    () => group(
      'inner',
      () => test('leaf', () {
        print('C4 named assertion');
        expect(1, 1);
      }),
    ),
  );
}
