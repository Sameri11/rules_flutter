import 'package:test_api/scaffolding.dart';

bool configWasRun = false;

Future<void> testExecutable(Future<void> Function() testMain) async {
  configWasRun = true;
  await testMain();
}
