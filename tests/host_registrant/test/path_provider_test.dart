import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('path_provider host implementation returns an existing documents directory', () async {
    debugPrint('PathProviderPlatform.instance = ${PathProviderPlatform.instance.runtimeType}');
    final dir = await getApplicationDocumentsDirectory();
    expect(Directory(dir.path).existsSync(), isTrue, reason: dir.path);
  });

  // Control for the registrant: the plugin's method channel, mocked. Passes only if
  // the default (method-channel) implementation is still the one in use.
  test('path_provider method channel, mocked, answers the documents path', () async {
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (call) async => '/mocked/documents',
    );
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    final dir = await getApplicationDocumentsDirectory();
    expect(dir.path, '/mocked/documents');
  });
}
