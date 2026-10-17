import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('materialized directory lists regular files', () {
    final entries = Directory(
      'test/fixtures/materialize',
    ).listSync(followLinks: false);
    expect(
      entries.map((e) => e.path.split('/').last),
      containsAll(['a.txt', 'b.txt']),
    );
    for (final entry in entries) {
      expect(entry, isA<File>());
    }
  });
}
