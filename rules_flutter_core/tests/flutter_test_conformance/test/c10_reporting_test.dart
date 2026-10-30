import 'package:flutter_test/flutter_test.dart';

void main() {
  print('C10 main declaration output');
  test('print capture first failure', () {
    print('C10 body output');
    printOnFailure('C10 printOnFailure marker');
    expect(1, 2, reason: 'C10 first failure marker');
  });
  test(
    'second failure',
    () => expect(3, 4, reason: 'C10 second failure marker'),
  );
  expect(1, 2, reason: 'C10 declaration error marker');
}
