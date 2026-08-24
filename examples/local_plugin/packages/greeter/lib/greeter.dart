
import 'greeter_platform_interface.dart';

class Greeter {
  Future<String?> getPlatformVersion() {
    return GreeterPlatform.instance.getPlatformVersion();
  }
}
