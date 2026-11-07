import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '{{LOGIC_IMPORT}}' as logic;
import '{{DECODER_IMPORT}}' as decoder;
import '{{FRAME_IMPORT}}' as frame;

/// A runner failure with a message for the user. Thrown instead of exiting, so
/// device cleanup in `finally` still runs.
final class _RunnerFailure implements Exception {
  _RunnerFailure(this.message);

  final String message;
}

Never _fail(String message) => throw _RunnerFailure(message);

Future<void> main(List<String> args) async {
  final started = DateTime.now();
  try {
    await _run(args, started);
  } on _RunnerFailure catch (error) {
    stderr.writeln('Android integration test runner: ${error.message}');
    exitCode = 1;
  } on FormatException catch (error) {
    stderr.writeln('Android integration test runner: ${error.message}');
    exitCode = 1;
  }
}

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

Future<void> _run(List<String> args, DateTime started) async {
  final options = _parseArgs(args);
  final adb = options['adb']!;
  final apk = options['apk']!;
  final package = options['package']!;
  final activity = options['activity']!;
  final runId = options['run-id']!;
  final timeout = int.tryParse(Platform.environment['TEST_TIMEOUT'] ?? '') ?? 120;
  final deadline = started.add(logic.runnerDeadline(Duration(seconds: timeout)));

  final port = int.tryParse(Platform.environment['ANDROID_ADB_SERVER_PORT'] ?? '5037');
  if (port == null || !await _reachable(port)) {
    _fail('ADB server is unreachable; start the emulator or run adb start-server on the host.');
  }
  logic.compareVersions(await _serverVersion(port), await _clientVersion(adb));

  final devicesResult = await Process.run(adb, ['devices']);
  _check(devicesResult, 'adb devices');
  final device = logic.selectDevice(
    logic.parseDevices(devicesResult.stdout as String),
    Platform.environment['ANDROID_SERIAL'],
  );

  final session = _DeviceSession(adb, device, package);
  final signals = [
    for (final signal in [ProcessSignal.sigterm, ProcessSignal.sigint])
      signal.watch().listen((received) async {
        stderr.writeln('Android integration test runner: interrupted by $received; cleaning up.');
        await session.cleanup();
        exit(received == ProcessSignal.sigint ? 130 : 143);
      }),
  ];
  try {
    await _install(session, apk);
    _check(await session.shell(['pm', 'clear', package]), 'pm clear');
    await _writeSettings(session, runId);
    _check(await session.adb(['logcat', '-c']), 'logcat clear');
    await session.startLogcat();
    _check(await session.shell(['am', 'start', '-W', '-n', '$package/$activity']), 'am start');
    session.launched = true;
    await _await(session, runId, deadline);
  } finally {
    await session.cleanup();
    for (final subscription in signals) {
      await subscription.cancel();
    }
  }
}

/// The device side of one run. [cleanup] is idempotent, so the signal handler
/// and the normal exit path can both call it.
final class _DeviceSession {
  _DeviceSession(this.adbPath, this.serial, this.package);

  final String adbPath;
  final String serial;
  final String package;
  final StringBuffer captured = StringBuffer();
  Process? _logcat;
  StreamSubscription<String>? _capture;
  Future<void>? _cleanup;

  /// Whether the app was started, so it may have written outputs.
  bool launched = false;

  String get testDirectory => '/data/user/0/$package/code_cache/rules_flutter_test';

  Future<ProcessResult> adb(List<String> arguments) =>
      Process.run(adbPath, ['-s', serial, ...arguments]);

  Future<ProcessResult> shell(List<String> arguments) => adb(['shell', ...arguments]);

  Future<void> startLogcat() async {
    final logcat = await Process.start(adbPath, ['-s', serial, 'logcat', '-v', 'brief']);
    _logcat = logcat;
    _capture = logcat.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(captured.write);
    unawaited(logcat.stderr.drain<void>());
  }

  Future<void> stopLogcat() async {
    _logcat?.kill();
    _logcat = null;
    await _capture?.cancel();
    _capture = null;
  }

  Future<void> cleanup() => _cleanup ??= _runCleanup();

  Future<void> _runCleanup() async {
    await stopLogcat();
    await shell(['am', 'force-stop', package]);
    try {
      if (launched) await _copyOutputs(this);
    } on _RunnerFailure catch (error) {
      stderr.writeln('Android integration test runner: ${error.message}');
      exitCode = 1;
    } finally {
      await adb(['uninstall', package]);
    }
  }
}

Future<void> _install(_DeviceSession session, String apk) async {
  var install = await session.adb(['install', '-r', '-g', apk]);
  if ('${install.stdout}${install.stderr}'.contains('INSTALL_FAILED_UPDATE_INCOMPATIBLE')) {
    stderr.writeln('Existing APK has a different signature; uninstalling before retry.');
    await session.adb(['uninstall', session.package]);
    install = await session.adb(['install', '-r', '-g', apk]);
  }
  _check(install, 'adb install');
}

Future<void> _writeSettings(_DeviceSession session, String runId) async {
  final directory = session.testDirectory;
  _check(
    await session.shell(['run-as', session.package, 'mkdir', '-p', directory]),
    'run-as settings directory',
  );
  final settings = <String, Object>{'version': 1, 'runId': runId};
  final filter = Platform.environment['TESTBRIDGE_TEST_ONLY'];
  if (filter != null && filter.isNotEmpty) settings['nameFilter'] = filter;
  final write = await Process.start(session.adbPath, [
    '-s', session.serial, 'shell', 'run-as', session.package, 'sh', '-c',
    "'cat > $directory/run_settings.json'",
  ]);
  unawaited(write.stdout.drain<void>());
  unawaited(write.stderr.drain<void>());
  write.stdin.write(jsonEncode(settings));
  await write.stdin.close();
  final code = await write.exitCode;
  if (code != 0) _fail('run-as settings write failed with exit code $code.');
}

/// Waits for the run's footer, a crash or the deadline, then reports.
Future<void> _await(_DeviceSession session, String runId, DateTime deadline) async {
  String text() => session.captured.toString();
  var crashed = false;
  var lastPidCheck = DateTime.now();
  while (!logic.hasFooter(text(), runId) && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 250));
    if (!logic.hasRunFrame(text(), runId) ||
        DateTime.now().difference(lastPidCheck) < const Duration(seconds: 1)) {
      continue;
    }
    lastPidCheck = DateTime.now();
    final pid = await session.shell(['pidof', session.package]);
    if (pid.exitCode == 0 && pid.stdout.toString().trim().isNotEmpty) continue;
    if (await logic.awaitFooter(text, runId, const Duration(milliseconds: 1500))) break;
    crashed = true;
    break;
  }
  final timedOut = !crashed && !logic.hasFooter(text(), runId);
  await session.stopLogcat();
  final output = text();
  final runningCase = logic.runningCase(output, runId, frame.unescapePayload);

  List<decoder.CaseResult> cases;
  var failed = crashed || timedOut;
  if (crashed || timedOut) {
    if (timedOut) {
      stdout.writeln('Integration test deadline exceeded; last events:');
      final events = RegExp(r'RFT\|[^\n]*').allMatches(output).toList();
      for (final event in events.skip(events.length > 20 ? events.length - 20 : 0)) {
        stdout.writeln(event.group(0));
      }
    } else {
      stderr.writeln('Integration test process exited while running: ${runningCase ?? 'no case'}');
    }
    cases = [
      decoder.CaseResult(
        runningCase ?? 'integration test runner',
        decoder.Outcome.error,
        timedOut ? 'Overall runner deadline exceeded.' : 'Application exited before RFT_END.',
      ),
    ];
  } else {
    try {
      final decoded = decoder.decodeStream(output, run: runId);
      cases = decoded.cases;
      failed = decoded.status != 0;
    } on decoder.DecodeError catch (error) {
      failed = true;
      cases = [
        decoder.CaseResult(
          'integration test stream',
          decoder.Outcome.error,
          'Could not decode the device stream: ${error.message}',
        ),
      ];
    }
  }
  for (final testCase in cases) {
    stdout.writeln('${testCase.outcome.name.toUpperCase()}: ${testCase.name}');
    if (testCase.message.isNotEmpty && testCase.outcome != decoder.Outcome.pass) {
      stdout.writeln(testCase.message);
    }
  }
  final xmlPath = Platform.environment['XML_OUTPUT_FILE'];
  if (xmlPath != null) {
    await File(xmlPath).writeAsString(decoder.junitReport('device', cases, ''));
  }
  if (failed) exitCode = 1;
}

Future<void> _copyOutputs(_DeviceSession session) async {
  final destination = Platform.environment['TEST_UNDECLARED_OUTPUTS_DIR'];
  if (destination == null) return;
  await Directory(destination).create(recursive: true);
  final archive = await Process.start(session.adbPath, [
    '-s', session.serial, 'exec-out', 'run-as', session.package, 'tar', '-C',
    session.testDirectory, '-cf', '-', 'outputs',
  ]);
  final extract = await Process.start('tar', ['-xf', '-', '-C', destination]);
  unawaited(archive.stderr.drain<void>());
  unawaited(extract.stdout.drain<void>());
  unawaited(extract.stderr.drain<void>());
  await archive.stdout.pipe(extract.stdin);
  final results = await Future.wait([archive.exitCode, extract.exitCode]);
  if (results.any((code) => code != 0)) {
    _fail('Could not retrieve integration test outputs.');
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
