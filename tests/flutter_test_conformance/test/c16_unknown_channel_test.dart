import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('unknown channel message', () {
    final channel = Zone.current[#test.runner.test_channel] as dynamic;
    channel.sink.add({'type': 'bogus'});
  });
  test('after the unknown message', () {});
}
