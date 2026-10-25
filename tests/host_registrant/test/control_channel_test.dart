import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

// Control: a channel no plugin owns. It must pass in every arm.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a mocked method channel answers under flutter test and Bazel alike', () async {
    const channel = MethodChannel('bnt05/control');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (call) async => 'mocked:${call.method}',
    );
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    expect(await channel.invokeMethod<String>('ping'), 'mocked:ping');
  });
}
