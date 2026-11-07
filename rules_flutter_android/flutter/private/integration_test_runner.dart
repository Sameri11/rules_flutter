import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '{{DECODER_IMPORT}}' as decoder;

Future<void> main(List<String> args) async {
  if (args.length != 5) _fail('usage: runner adb apk package activity run-id');
  final adb = args[0];
  final apk = args[1];
  final package = args[2];
  final activity = args[3];
  final runId = args[4];
  final port = int.tryParse(Platform.environment['ANDROID_ADB_SERVER_PORT'] ?? '5037');
  if (port == null || !await _reachable(port)) {
    _fail('ADB server is unreachable; start the emulator or run adb start-server on the host.');
  }
  final serverVersion = await _serverVersion(port);
  final clientVersion = await _clientVersion(adb);
  if (serverVersion != clientVersion) {
    _fail('ADB client/server version mismatch; start the server with the declared SDK adb.');
  }

  final devicesResult = await Process.run(adb, ['devices']);
  _check(devicesResult, 'adb devices');
  final devices = (devicesResult.stdout as String)
      .split('\n')
      .skip(1)
      .map((line) => line.trim().split(RegExp(r'\s+')))
      .where((fields) => fields.length > 1 && fields[1] == 'device')
      .map((fields) => fields[0])
      .toList();
  final serial = Platform.environment['ANDROID_SERIAL'];
  final device = serial ?? (devices.length == 1 ? devices.single : null);
  if (device == null || !devices.contains(device)) {
    _fail(serial == null
        ? 'Expected exactly one Android device; found ${devices.length}.'
        : 'ANDROID_SERIAL $serial is not an available device.');
  }

  Process? logcat;
  StreamSubscription<String>? subscription;
  try {
    var install = await Process.run(adb, ['-s', device, 'install', '-r', '-g', apk]);
    if ((install.stdout.toString() + install.stderr.toString())
        .contains('INSTALL_FAILED_UPDATE_INCOMPATIBLE')) {
      await Process.run(adb, ['-s', device, 'uninstall', package]);
      install = await Process.run(adb, ['-s', device, 'install', '-r', '-g', apk]);
    }
    _check(install, 'adb install');
    _check(await Process.run(adb, ['-s', device, 'shell', 'pm', 'clear', package]), 'pm clear');

    final settingsDirectory = '/data/user/0/$package/code_cache/rules_flutter_test';
    _check(
      await Process.run(adb, [
        '-s', device, 'shell', 'run-as', package, 'mkdir', '-p', settingsDirectory,
      ]),
      'run-as settings directory',
    );
    final settings = <String, Object>{'version': 1, 'runId': runId};
    final filter = Platform.environment['TESTBRIDGE_TEST_ONLY'];
    if (filter != null && filter.isNotEmpty) settings['nameFilter'] = filter;
    final write = await Process.start(adb, [
      '-s', device, 'shell', 'run-as', package, 'sh', '-c',
      "'cat > $settingsDirectory/run_settings.json'",
    ]);
    write.stdin.write(jsonEncode(settings));
    await write.stdin.close();
    final writeCode = await write.exitCode;
    if (writeCode != 0) _fail('run-as settings write failed with exit code $writeCode.');

    _check(await Process.run(adb, ['-s', device, 'logcat', '-c']), 'logcat clear');
    logcat = await Process.start(adb, ['-s', device, 'logcat', '-v', 'brief']);
    final captured = StringBuffer();
    final captureSubscription = logcat.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen((text) => captured.write(text));
    subscription = captureSubscription;
    _check(
      await Process.run(adb, [
        '-s', device, 'shell', 'am', 'start', '-W', '-n', '$package/$activity',
      ]),
      'am start',
    );

    final footer = 'RFT_END|$runId|';
    final deadline = DateTime.now().add(const Duration(minutes: 2));
    while (!captured.toString().contains(footer) && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    await logcat.kill();
    await captureSubscription.cancel();
    final decoded = decoder.decodeStream(captured.toString(), run: runId);
    for (final testCase in decoded.cases) {
      stdout.writeln('${testCase.outcome.name.toUpperCase()}: ${testCase.name}');
    }
    final xmlPath = Platform.environment['XML_OUTPUT_FILE'];
    if (xmlPath != null) {
      await File(xmlPath).writeAsString(
        decoder.junitReport('device', decoded.cases, ''),
      );
    }
    if (decoded.status != 0) exitCode = 1;
  } finally {
    await subscription?.cancel();
    if (logcat != null) await logcat.kill();
    await Process.run(adb, ['-s', device, 'shell', 'am', 'force-stop', package]);
    await Process.run(adb, ['-s', device, 'uninstall', package]);
  }
}

Future<bool> _reachable(int port) async {
  try {
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      port,
      timeout: const Duration(seconds: 2),
    );
    socket.destroy();
    return true;
  } on SocketException {
    return false;
  } on TimeoutException {
    return false;
  }
}

Future<int> _serverVersion(int port) async {
  final socket = await Socket.connect(
    InternetAddress.loopbackIPv4,
    port,
    timeout: const Duration(seconds: 2),
  );
  try {
    socket.add(utf8.encode('000Chost:version'));
    await socket.flush();
    final chunks = StreamIterator<List<int>>(socket);
    final bytes = <int>[];
    while (bytes.length < 8 && await chunks.moveNext()) {
      bytes.addAll(chunks.current);
    }
    if (bytes.length < 8 || ascii.decode(bytes.take(4).toList()) != 'OKAY') {
      _fail('ADB server rejected its version request.');
    }
    final length = int.parse(ascii.decode(bytes.sublist(4, 8)), radix: 16);
    while (bytes.length < 8 + length && await chunks.moveNext()) {
      bytes.addAll(chunks.current);
    }
    if (bytes.length < 8 + length) _fail('ADB server returned a truncated version.');
    return int.parse(ascii.decode(bytes.sublist(8, 8 + length)), radix: 16);
  } finally {
    socket.destroy();
  }
}

Future<int> _clientVersion(String adb) async {
  final result = await Process.run(adb, ['version']);
  _check(result, 'adb version');
  final match = RegExp(r'Android Debug Bridge version 1\.0\.(\d+)')
      .firstMatch(result.stdout as String);
  if (match == null) _fail('Could not read the declared adb client version.');
  return int.parse(match.group(1)!);
}

void _check(ProcessResult result, String operation) {
  if (result.exitCode != 0) {
    _fail('$operation failed: ${result.stdout}${result.stderr}');
  }
}

Never _fail(String message) {
  stderr.writeln('Android integration test runner: $message');
  exit(1);
}
