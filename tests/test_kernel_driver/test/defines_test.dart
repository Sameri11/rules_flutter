import 'package:kernel_fixture/app.dart';
import 'package:kernel_fixture/extra.dart';

const name = String.fromEnvironment('FIXTURE_NAME');
const enabled = bool.fromEnvironment('FIXTURE_ENABLED');

void main() => print('$name $enabled ${greeting()} ${extra()}');
