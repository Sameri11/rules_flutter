import '../support/marker.dart';

Future<void> testExecutable(Future<void> Function() testMain) async {
  nestedConfigRan = true;
  await testMain();
}
