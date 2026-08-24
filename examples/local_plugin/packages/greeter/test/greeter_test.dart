import 'package:flutter_test/flutter_test.dart';
import 'package:greeter/greeter.dart';
import 'package:greeter/greeter_platform_interface.dart';
import 'package:greeter/greeter_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockGreeterPlatform
    with MockPlatformInterfaceMixin
    implements GreeterPlatform {
  @override
  Future<String?> getPlatformVersion() => Future.value('42');
}

void main() {
  final GreeterPlatform initialPlatform = GreeterPlatform.instance;

  test('$MethodChannelGreeter is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelGreeter>());
  });

  test('getPlatformVersion', () async {
    Greeter greeterPlugin = Greeter();
    MockGreeterPlatform fakePlatform = MockGreeterPlatform();
    GreeterPlatform.instance = fakePlatform;

    expect(await greeterPlugin.getPlatformVersion(), '42');
  });
}
