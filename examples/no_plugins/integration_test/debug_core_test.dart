// Entrypoint of the flutter_debug_core fixture: a plain `main` with no test
// framework. Its define marks which kernel the artifact runs.
import 'debug_core_helper.dart';

void main() {
  const mark = String.fromEnvironment('IDENTITY_TEST_MARK', defaultValue: 'unset');
  print('identity test mark=$mark helper=${helperLabel()}');
}
