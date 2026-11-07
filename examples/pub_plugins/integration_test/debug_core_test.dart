// Entrypoint of the flutter_debug_core fixture: a plain `main` with no test
// framework. Its define marks which kernel the artifact runs.
import 'debug_core_helper.dart';
import 'package:path_provider/path_provider.dart';

Future<void> main() async {
  const mark = String.fromEnvironment('DEBUG_CORE_MARK', defaultValue: 'unset');
  final directory = await getTemporaryDirectory();
  print('debug core mark=$mark helper=${helperLabel()} plugin=${directory.path}');
}
