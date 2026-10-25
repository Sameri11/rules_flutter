import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

// No mocks: whatever PlatformInterface.instance holds after the registrant (if any) runs.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('shared_preferences host implementation round-trips a string', () async {
    debugPrint('SharedPreferencesStorePlatform.instance = ${SharedPreferencesStorePlatform.instance.runtimeType}');
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('bnt05', 'value');
    expect(prefs.getString('bnt05'), 'value');
  });
}
