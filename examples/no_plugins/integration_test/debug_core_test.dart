// Entrypoint of the flutter_debug_core fixture: a plain `main` with no test
// framework. Its define marks which kernel the artifact runs.
import 'debug_core_helper.dart';

void main() {
  const mark = String.fromEnvironment('DEBUG_CORE_MARK', defaultValue: 'unset');
  print('debug core mark=$mark helper=${helperLabel()}');
}
