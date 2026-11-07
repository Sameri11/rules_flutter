import 'dart:io';

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('shows the app', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Text('integration pass')));
    expect(find.text('integration pass'), findsOneWidget);
  });
  testWidgets('captures a screenshot output', (tester) async {
    final boundaryKey = GlobalKey();
    await tester.pumpWidget(MaterialApp(
      home: RepaintBoundary(
        key: boundaryKey,
        child: const Scaffold(body: Center(child: Text('screenshot fixture'))),
      ),
    ));
    final boundary = boundaryKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final output = File(
      '${Directory.systemTemp.path}/rules_flutter_test/outputs/screenshot.png',
    );
    await output.parent.create(recursive: true);
    await output.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
    expect(output.existsSync(), isTrue);
  });

  testWidgets('shows another widget', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Text('second pass')));
    expect(find.text('second pass'), findsOneWidget);
  });
}
