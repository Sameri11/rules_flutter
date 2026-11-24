@Skip('per-file skip sentinel')
@Timeout(Duration(seconds: 3))
@Tags(<String>['grouped-skipped'])
@TestOn('vm')
library;
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('library metadata skip is honored', () => fail('must stay skipped'));
}
