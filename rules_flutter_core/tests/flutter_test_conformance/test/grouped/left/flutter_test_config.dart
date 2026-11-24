import '../../grouped_shared.dart';

Future<void> testExecutable(Future<void> Function() testMain) async {
  state.add('left-config-before');
  await testMain();
  state.add('left-config-after');
}
