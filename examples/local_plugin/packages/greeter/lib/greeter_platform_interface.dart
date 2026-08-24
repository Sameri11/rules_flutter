import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'greeter_method_channel.dart';

abstract class GreeterPlatform extends PlatformInterface {
  /// Constructs a GreeterPlatform.
  GreeterPlatform() : super(token: _token);

  static final Object _token = Object();

  static GreeterPlatform _instance = MethodChannelGreeter();

  /// The default instance of [GreeterPlatform] to use.
  ///
  /// Defaults to [MethodChannelGreeter].
  static GreeterPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [GreeterPlatform] when
  /// they register themselves.
  static set instance(GreeterPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }
}
