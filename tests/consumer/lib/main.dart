import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

const _pluginChannel = MethodChannel('fake_plugin');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    final result = await _pluginChannel.invokeMethod<String>(
      'ping',
      'com.example.fake_plugin.ConsumerRuleProbe',
    );
    debugPrint('consumer-plugin-result: $result');
  } catch (error) {
    debugPrint('consumer-plugin-error: $error');
  }
}
