import 'marker.dart';

Future<void> testExecutable(Future<void> Function() testMain) async {
  subConfigRan = true;
  await testMain();
}
