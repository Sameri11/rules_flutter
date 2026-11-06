import 'package:path_provider/path_provider.dart';

Future<void> main() async {
  const mark = String.fromEnvironment('DEBUG_CORE_MARK', defaultValue: 'unset');
  final directory = await getTemporaryDirectory();
  print('debug core mark=$mark plugin=${directory.path}');
}
