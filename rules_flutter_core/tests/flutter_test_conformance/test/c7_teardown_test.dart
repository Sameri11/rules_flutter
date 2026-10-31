import 'package:flutter_test/flutter_test.dart';

void main() {
  test('addTearDown', () {
    addTearDown(() => print('C7 addTearDown ran'));
    expect(true, isTrue);
  });
  group('failing setup group', () {
    setUpAll(() => throw StateError('setUpAll failure marker'));
    test('blocked by setup', () {});
  });
  group('failing teardown group', () {
    tearDownAll(() => throw StateError('tearDownAll failure marker'));
    test('teardown all', () {});
  });
  group('failing tearDown', () {
    tearDown(() => throw StateError('tearDown failure marker'));
    test('tearDown body', () {});
  });
  group('outer', () {
    group('inner', () {
      setUpAll(() => throw StateError('nested setUpAll failure marker'));
      test('nested blocked', () {});
    });
  });
  group('outer teardown', () {
    group('inner teardown', () {
      tearDownAll(() => throw StateError('nested tearDownAll failure marker'));
      test('nested teardown test', () {});
    });
  });
  tearDownAll(() => throw StateError('root tearDownAll failure marker'));
}
