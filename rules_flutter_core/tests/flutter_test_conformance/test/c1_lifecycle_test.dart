import 'package:flutter_test/flutter_test.dart';

final events = <String>[];
void main() {
  setUpAll(() => events.add('root setUpAll'));
  tearDownAll(() => events.add('root tearDownAll'));
  setUp(() => events.add('root setUp'));
  tearDown(() => events.add('root tearDown'));
  group('outer', () {
    setUpAll(() => events.add('outer setUpAll'));
    tearDownAll(() => events.add('outer tearDownAll'));
    setUp(() => events.add('outer setUp'));
    tearDown(() => events.add('outer tearDown'));
    test('first', () => events.add('first'));
    test('second', () => events.add('second'));
  });
  test('lifecycle order', () {
    final expected = [
      'root setUpAll',
      'outer setUpAll',
      'root setUp',
      'outer setUp',
      'first',
      'outer tearDown',
      'root tearDown',
      'root setUp',
      'outer setUp',
      'second',
      'outer tearDown',
      'root tearDown',
      'outer tearDownAll',
      'root setUp',
    ];
    print('C1 events: ${events.join(' | ')}');
    expect(events, expected);
  });
}
