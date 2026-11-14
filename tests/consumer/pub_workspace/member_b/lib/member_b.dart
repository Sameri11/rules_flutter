import 'package:path_provider/path_provider.dart';

Future<String> memberB() async => (await getTemporaryDirectory()).path;
