import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

final state = <String>[];
TestWidgetsFlutterBinding? savedBinding;
Timer? leakedTimer;

class FixtureHttpOverrides extends HttpOverrides {}
