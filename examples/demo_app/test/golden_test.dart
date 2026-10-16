import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

// Rendering may differ across OSes and SDK versions; each OS keeps its own file so either can be regenerated alone.
String get _golden {
  if (Platform.isMacOS) return 'goldens/solid_tiles_macos.png';
  if (Platform.isLinux) return 'goldens/solid_tiles_linux.png';
  throw UnsupportedError('no golden for ${Platform.operatingSystem}');
}

void main() {
  testWidgets('solid tiles match the golden', (tester) async {
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(
          width: 64,
          height: 32,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: const [
              SizedBox(
                width: 32,
                height: 32,
                child: ColoredBox(color: Color(0xFFFF0000)),
              ),
              SizedBox(
                width: 32,
                height: 32,
                child: ColoredBox(color: Color(0xFF00FF00)),
              ),
            ],
          ),
        ),
      ),
    );
    await expectLater(find.byType(Row), matchesGoldenFile(_golden));
  });
}
