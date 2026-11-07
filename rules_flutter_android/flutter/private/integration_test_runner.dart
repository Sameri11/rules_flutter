import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '{{LOGIC_IMPORT}}' as logic;
import '{{DECODER_IMPORT}}' as decoder;

Map<String, String> _parseArgs(List<String> args) {
  final options = <String, String>{};
  for (var i = 0; i < args.length; i += 2) {
    if (i + 1 >= args.length || !args[i].startsWith('--')) {
      _fail('usage: runner --adb PATH --apk PATH --package ID --activity NAME --run-id ID');
    }
    options[args[i].substring(2)] = args[i + 1];
  }
  for (final key in ['adb', 'apk', 'package', 'activity', 'run-id']) {
    if (!options.containsKey(key)) _fail('missing --$key');
  }
  return options;
}

Future<void> main(List<String> args) async {
  final options = _parseArgs(args);
  final adb = options['adb']!;
  final apk = options['apk']!;
  final package = options['package']!;
  final activity = options['activity']!;
  final runId = options['run-id']!;
  final port = int.tryParse(Platform.environment['ANDROID_ADB_SERVER_PORT'] ?? '5037');
  if (port == null || !await _reachable(port)) {
    _fail('ADB server is unreachable; start the emulator or run adb start-server on the host.');
  }
  final serverVersion = await _serverVersion(port);
  final clientVersion = await _clientVersion(adb);
  logic.compareVersions(serverVersion, clientVersion);

  final devicesResult = await Process.run(adb, ['devices']);
  _check(devicesResult, 'adb devices');
  final devices = logic.parseDevices(devicesResult.stdout as String);
  final serial = Platform.environment['ANDROID_SERIAL'];
  final device = logic.selectDevice(devices, serial);
  final footer = 'RFT_END|$runId|';

  Process? logcat;
  StreamSubscription<String>? subscription;
  try {
    var install = await Process.run(adb, ['-s', device, 'install', '-r', '-g', apk]);
    if ((install.stdout.toString() + install.stderr.toString())
        .contains('INSTALL_FAILED_UPDATE_INCOMPATIBLE')) {
      stderr.writeln('Existing APK has a different signature; uninstalling before retry.');
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

    final timeout = int.tryParse(Platform.environment['TEST_TIMEOUT'] ?? '') ?? 120;
    final deadlineSeconds = timeout > 20 ? timeout - 15 : timeout;
    final deadline = DateTime.now().add(Duration(seconds: deadlineSeconds));
    var timedOut = false;
    var crashed = false;
    var lastPidCheck = DateTime.now();
    while (!logic.hasFooter(captured.toString(), runId) && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      final current = captured.toString();
      final runningCase = _runningCase(current, runId);
      if (runningCase != null && DateTime.now().difference(lastPidCheck).inSeconds >= 1) {
        lastPidCheck = DateTime.now();
        final pid = await Process.run(adb, ['-s', device, 'shell', 'pidof', package]);
        if (pid.exitCode != 0 || pid.stdout.toString().trim().isEmpty) {
          crashed = true;
          stderr.writeln('Integration test process exited while running: $runningCase');
          break;
        }
      }
    }
    if (!logic.hasFooter(captured.toString(), runId) && !crashed) {
      timedOut = true;
      final text = captured.toString();
      stdout.writeln('Integration test deadline exceeded; last events:');
      final events = RegExp(r'RFT\|[^\n]*').allMatches(text).toList();
      for (final event in events.skip(events.length > 20 ? events.length - 20 : 0)) {
        stdout.writeln(event.group(0));
      }
    }
    await logcat.kill();
    await captureSubscription.cancel();
    final output = captured.toString();
    final runningCase = _runningCase(output, runId);
    final decoded = timedOut || crashed ? null : decoder.decodeStream(output, run: runId);
    final cases = decoded?.cases ?? [
      decoder.CaseResult(
        runningCase ?? 'integration test runner',
        decoder.Outcome.error,
        timedOut ? 'Overall runner deadline exceeded.' : 'Application exited before RFT_END.',
      ),
    ];
    for (final testCase in cases) {
      stdout.writeln('${testCase.outcome.name.toUpperCase()}: ${testCase.name}');
    }
    if (runningCase != null && decoded == null) {
      stderr.writeln('Integration test interrupted while running: $runningCase');
    }
    final xmlPath = Platform.environment['XML_OUTPUT_FILE'];
    if (xmlPath != null) {
      await File(xmlPath).writeAsString(
        decoder.junitReport('device', cases, ''),
      );
    }
    if (timedOut || decoded == null || decoded.status != 0) exitCode = 1;
  } finally {
    await subscription?.cancel();
    if (logcat != null) await logcat.kill();
    await Process.run(adb, ['-s', device, 'shell', 'am', 'force-stop', package]);
    try {
      await _copyOutputs(adb, device, package);
    } finally {
      await Process.run(adb, ['-s', device, 'uninstall', package]);
    }
  }
}

Future<void> _copyOutputs(String adb, String device, String package) async {
  final destination = Platform.environment['TEST_UNDECLARED_OUTPUTS_DIR'];
  if (destination == null) return;
  await Directory(destination).create(recursive: true);
  final archive = await Process.start(adb, [
    '-s', device, 'exec-out', 'run-as', package, 'tar', '-C',
    '/data/user/0/$package/code_cache/rules_flutter_test', '-cf', '-', 'outputs',
  ]);
  final extract = await Process.start('tar', ['-xf', '-', '-C', destination]);
  await archive.stdout.pipe(extract.stdin);
  final results = await Future.wait([archive.exitCode, extract.exitCode]);
  if (results.any((code) => code != 0)) {
    throw StateError('Could not retrieve integration test outputs.');
  }
}
String? _runningCase(String text, String runId) => logic.runningCase(text, runId);


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
