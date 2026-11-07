import 'dart:convert';

/// Parses online devices from `adb devices -l`; inaccessible devices are errors.
List<String> parseDevices(String text) {
  final devices = <String>[];
  for (final line in text.split('\n').skip(1)) {
    final fields = line.trim().split(RegExp(r'\s+'));
    if (fields.length < 2 || fields.first.isEmpty) continue;
    if (fields[1] == 'device') {
      devices.add(fields.first);
    } else if (fields[1] == 'unauthorized' || fields[1] == 'offline') {
      throw FormatException('Android device ${fields.first} is ${fields[1]}.');
    }
  }
  return devices;
}

String selectDevice(List<String> devices, String? serial) {
  if (serial != null && serial.isNotEmpty) {
    if (!devices.contains(serial)) {
      throw FormatException('ANDROID_SERIAL $serial is not an available device.');
    }
    return serial;
  }
  if (devices.length != 1) {
    throw FormatException('Expected exactly one Android device; found ${devices.length}.');
  }
  return devices.single;
}

String? runningCase(String text, String runId) {
  String? name;
  for (final line in text.split('\n')) {
    if (!line.contains('RFT|$runId|')) continue;
    final match = RegExp(r'"type":"running","name":"((?:\\.|[^"\\])*)"')
        .firstMatch(line);
    if (match != null) {
      name = (jsonDecode('"${match.group(1)}"') as String).replaceAllMapped(
        RegExp(r'%u([0-9A-Fa-f]{4})'),
        (match) => String.fromCharCode(int.parse(match.group(1)!, radix: 16)),
      );
    }
  }
  return name;
}

bool hasFooter(String text, String runId) => text.contains('RFT_END|$runId|');

int compareVersions(int server, int client) {
  if (server != client) {
    throw FormatException(
      'ADB client/server version mismatch; start the server with the declared SDK adb.',
    );
  }
  return server;
}
