import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

final _events = <String>[];

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() => _events.add('setUpAll'));
  tearDownAll(() => expect(_events, ['setUpAll', 'setUp', 'test', 'tearDown']));
  setUp(() => _events.add('setUp'));
  tearDown(() => _events.add('tearDown'));

  testWidgets('runs lifecycle hooks in order', (tester) async {
    _events.add('test');
    expect(_events, ['setUpAll', 'setUp', 'test']);
  });
}
