import 'package:flutter_test/flutter_test.dart';
import 'package:workspace_member/member.dart';

void main() {
  test('member imports its workspace dependency', () {
    expect(member, isA<Function>());
  });
}
