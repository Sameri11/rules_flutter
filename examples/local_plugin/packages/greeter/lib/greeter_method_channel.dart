import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'greeter_platform_interface.dart';

/// An implementation of [GreeterPlatform] that uses method channels.
class MethodChannelGreeter extends GreeterPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('greeter');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>(
      'getPlatformVersion',
    );
    return version;
  }
}
