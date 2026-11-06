import 'debug_core_helper.dart';

void main() {
  const mark = String.fromEnvironment('IDENTITY_TEST_MARK', defaultValue: 'unset');
  print('identity test two mark=$mark helper=${helperLabel()}');
}
