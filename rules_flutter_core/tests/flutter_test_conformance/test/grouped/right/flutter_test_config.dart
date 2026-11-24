import '../../grouped_shared.dart';

Future<void> testExecutable(Future<void> Function() testMain) async {
  state.add('right-config-before');
  await testMain();
  state.add('right-config-after');
}
