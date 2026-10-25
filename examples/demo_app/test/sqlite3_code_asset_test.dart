import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test('sqlite3 code asset opens an in-memory database', () {
    final database = sqlite3.openInMemory();
    database.close();
  });
}
