import 'dart:convert';

/// One `adb devices` entry.
final class Device {
  const Device(this.serial, this.state);

  final String serial;

  /// `device` when usable; otherwise `offline`, `unauthorized`, and so on.
  final String state;
}

/// Parses `adb devices` output into its entries, whatever their state.
List<Device> parseDevices(String text) {
  final devices = <Device>[];
  for (final line in text.split('\n').skip(1)) {
    final fields = line.trim().split(RegExp(r'\s+'));
    if (fields.length < 2 || fields.first.isEmpty) continue;
    devices.add(Device(fields.first, fields[1]));
  }
  return devices;
}

/// The serial to run on: [serial] when set, otherwise the only attached
/// device. Only the selected device has to be usable, so an offline device
/// elsewhere does not block an explicit serial.
String selectDevice(List<Device> devices, String? serial) {
  final Device device;
  if (serial != null && serial.isNotEmpty) {
    final matches = devices.where((entry) => entry.serial == serial);
    if (matches.isEmpty) {
      throw FormatException('ANDROID_SERIAL $serial is not an available device.');
    }
    device = matches.first;
  } else {
    if (devices.length != 1) {
      throw FormatException(
        'Expected exactly one Android device; found ${devices.length}. '
        'Set ANDROID_SERIAL to choose one.',
      );
    }
    device = devices.single;
  }
  if (device.state != 'device') {
    throw FormatException('Android device ${device.serial} is ${device.state}.');
  }
  return device.serial;
}

int compareVersions(int server, int client) {
  if (server != client) {
    throw FormatException(
      'ADB client/server version mismatch (server $server, client $client); '
      'start the server with the declared SDK adb.',
    );
  }
  return server;
}

/// Whether [text] carries any frame of [runId]: the test process has started.
bool hasRunFrame(String text, String runId) => text.contains('RFT|$runId|');

bool hasFooter(String text, String runId) => text.contains('RFT_END|$runId|');

/// The case the device reported as running last, or null between cases.
///
/// The stream is still being written, so incomplete or malformed events are
/// skipped rather than rejected; the full decoder validates the finished run.
/// [unescape] is the frame codec's payload unescape.
String? runningCase(
  String text,
  String runId,
  String Function(String) unescape,
) {
  final marker = 'RFT|$runId|';
  final chunks = <int, Map<int, String>>{};
  final counts = <int, int>{};
  for (var line in text.split('\n')) {
    if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
    final start = line.indexOf(marker);
    if (start < 0) continue;
    final fields = line.substring(start + marker.length).split('|');
    if (fields.length < 3) continue;
    final seq = int.tryParse(fields[0]);
    final position = fields[1].split('/');
    if (seq == null || position.length != 2) continue;
    final index = int.tryParse(position[0]);
    final count = int.tryParse(position[1]);
    if (index == null || count == null || index < 0 || index >= count) continue;
    if (counts.putIfAbsent(seq, () => count) != count) continue;
    chunks.putIfAbsent(seq, () => {})[index] = fields.sublist(2).join('|');
  }
  String? name;
  for (final seq in chunks.keys.toList()..sort()) {
    final parts = chunks[seq]!;
    final count = counts[seq]!;
    if (parts.length != count) continue;
    final Object? event;
    try {
      event = jsonDecode(unescape([for (var i = 0; i < count; i++) parts[i]].join()));
    } on FormatException {
      continue;
    }
    if (event is Map && event['type'] == 'running') {
      final running = event['name'];
      name = running is String ? running : null;
    }
  }
  return name;
}

/// The runner's own deadline, measured from its start. It stops short of
/// Bazel's TEST_TIMEOUT so force-stop, output retrieval and uninstall still
/// run before Bazel kills the test: a quarter of the timeout, at least 5 s
/// (or half of a tiny timeout) and at most 30 s.
Duration runnerDeadline(Duration testTimeout) {
  final seconds = testTimeout.inSeconds;
  final quarter = seconds ~/ 4 < 30 ? seconds ~/ 4 : 30;
  final floor = seconds ~/ 2 < 5 ? seconds ~/ 2 : 5;
  return Duration(seconds: seconds - (quarter > floor ? quarter : floor));
}

/// Waits up to [grace] for the footer of [runId] in [read]. The app exits right
/// after printing its footer, so logcat can deliver the footer after the
/// process is already gone.
Future<bool> awaitFooter(
  String Function() read,
  String runId,
  Duration grace,
) async {
  final stop = DateTime.now().add(grace);
  while (!hasFooter(read(), runId)) {
    if (!DateTime.now().isBefore(stop)) return false;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  return true;
}
