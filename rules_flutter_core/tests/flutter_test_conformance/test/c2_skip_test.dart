import 'package:flutter_test/flutter_test.dart';

void main() {
  test('skip true', () {}, skip: true);
  test('skip reason', () {}, skip: 'reason');
  group('skipped group', () {
    test('group child', () => fail('group skip was ignored'));
  }, skip: 'group reason');
  test('markTestSkipped', () => markTestSkipped('runtime reason'));
}
