import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pub_plugins/main.dart';
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('pumps the app root and calls the Android plugin', (tester) async {
    await tester.pumpWidget(const MyApp());
    final temporaryDirectory = await getTemporaryDirectory();
    expect(temporaryDirectory.path, isNotEmpty);

    await binding.convertFlutterSurfaceToImage();
    await tester.pumpAndSettle();
    final bytes = await binding.takeScreenshot('home');
    expect(bytes, isNotNull);
    final output = File(
      '${Directory.systemTemp.path}/rules_flutter_test/outputs/home.png',
    );
    await output.parent.create(recursive: true);
    await output.writeAsBytes(bytes!);
  });
}
