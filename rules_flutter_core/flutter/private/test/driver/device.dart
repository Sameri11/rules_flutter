/// Device flavor of the driver. It runs the suite inside an app on any
/// platform and reports each event as a framed `print` line; a runner captures
/// the lines from logcat or os_log and device_decoder.dart decodes them.
///
/// The bootstrap (device_bootstrap.dart.tmpl) calls [deviceMain]. It initializes
/// the integration-test binding before its test callback, in the declaration
/// zone, because the binding's constructor registers a tearDownAll. The
/// bootstrap compiles with INTEGRATION_TEST_SHOULD_REPORT_RESULTS_TO_NATIVE set
/// to false: frames carry the results, not the binding's native report.
///
/// This file never reads the environment. The name filter and shard come from
/// the run settings file, so every platform selects the same tests.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:test_api/backend.dart';

import 'core.dart';
import 'frame.dart';
import 'guard.dart';
import 'junit.dart';
import 'settings.dart';

/// Runs [testMain] as the suite and emits every event as frames, then the
/// footer. [testFile] is the suite's path, [packageRoot] the execroot path of
/// the pubspec directory (stack paths under it print relative to it) and
/// [metadataJson] the library's parsed test metadata.
///
/// Prints the footer and exits with the status on the desktop tester. On mobile
/// the runner stops the app once it has read the footer.
void deviceMain({
  required String testFile,
  required String packageRoot,
  required String metadataJson,
  required Future<void> Function() testMain,
}) {
  final emitter = _Emitter(_newRunId());
  final sink = _DeviceSink(emitter, packageRoot);

  final RunSettings settings;
  try {
    settings = _prepare();
  } on Object catch (error) {
    // Never run the unfiltered suite after a settings error.
    sink.caseDone(CaseResult('load', Outcome.error, '$error'));
    _finish(emitter, sink);
    return;
  }

  final late = <CaseResult>[];
  final channel = RemoteListener.start(
    () =>
        () => guarded(testMain, late),
  );
  final os = _operatingSystem();
  final filter = settings.nameFilter;
  final shardCount = settings.shardCount;
  final shardIndex = settings.shardIndex;
  unawaited(
    runCore(
      channel,
      CoreOptions(
        platform: <String, Object>{
          'runtime': Runtime.vm.serialize(),
          'compiler': Runtime.vm.defaultCompiler.serialize(),
          'os': os,
          'inGoogle': false,
        },
        platformVariables: <String>['vm', os],
        suitePath: testFile,
        sink: sink,
        metadata: jsonDecode(metadataJson) as Map<String, Object?>,
        nameFilter: filter == null ? null : RegExp(filter),
        shard: shardCount == null ? null : Shard(shardIndex!, shardCount),
      ),
      onComplete: (_) {
        for (final error in late) {
          sink.caseDone(error);
        }
        _finish(emitter, sink);
      },
    ),
  );
}

/// Creates the outputs directory, then reads the settings file. A missing file
/// selects everything. Throws for anything else that is wrong.
RunSettings _prepare() {
  final root = Directory.systemTemp.path;
  Directory('$root/$outputsPath').createSync(recursive: true);
  final file = File('$root/$runSettingsPath');
  if (!file.existsSync()) {
    return const RunSettings();
  }
  return parseRunSettings(file.readAsStringSync());
}

void _finish(_Emitter emitter, _DeviceSink sink) {
  final failed = sink.outcomes.any(
    (outcome) => outcome == Outcome.fail || outcome == Outcome.error,
  );
  final status = failed ? 1 : 0;
  emitter.event({
    'type': 'complete',
    'caseCount': sink.outcomes.length,
    'status': status,
  });
  emitter.end(status);
  if (!Platform.isAndroid && !Platform.isIOS) {
    stdout.flush().whenComplete(() => exit(status));
  }
}

String _newRunId() {
  final time = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  final random = Random.secure().nextInt(1 << 31).toRadixString(36);
  return '$time$random';
}

/// Prints outside the test's zone, which captures print output.
void _print(String line) => Zone.root.run(() => print(line));

final class _Emitter {
  _Emitter(this.run);

  final String run;
  var _seq = 0;

  /// Emits one event, split over as many frames as it needs.
  void event(Map<String, Object?> fields) {
    final seq = _seq++;
    final json = jsonEncode({'run': run, 'seq': seq, ...fields});
    for (final line in encodeEvent(run, seq, escapePayload(json))) {
      _print(line);
    }
  }

  void end(int status) => _print(footerLine(run, status));
}

final class _DeviceSink implements EventSink {
  _DeviceSink(this._emitter, this._packageRoot);

  final _Emitter _emitter;
  final String _packageRoot;

  /// The outcome of every case reported, in run order.
  final List<Outcome> outcomes = [];

  @override
  void message(String text) => _emitter.event({
    'type': 'message',
    'text': displayPath(text, _packageRoot),
  });

  @override
  void setRunning(String? name) =>
      _emitter.event({'type': 'running', 'name': name});

  @override
  void caseDone(CaseResult result) {
    outcomes.add(result.outcome);
    _emitter.event({
      'type': 'case',
      'name': result.name,
      'outcome': result.outcome.name,
      'message': displayPath(result.message, _packageRoot),
    });
  }
}

String _operatingSystem() => switch (Platform.operatingSystem) {
  'macos' => 'mac-os',
  'windows' => 'windows',
  'linux' => 'linux',
  'android' => 'android',
  'ios' => 'ios',
  _ => 'none',
};
