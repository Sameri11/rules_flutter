/// Host driver: runs the suite in-process on flutter_tester, with the test's
/// runfiles and undeclared outputs.
///
/// The bootstrap (bootstrap.dart.tmpl) calls [hostMain]. Filters and shards
/// come from `TESTBRIDGE_TEST_ONLY` and `TEST_TOTAL_SHARDS`/`TEST_SHARD_INDEX`.
/// Goldens are compared under `bazel test`. The update target sets
/// `FLUTTER_TEST_UPDATE_GOLDENS` to the test file's source path, and goldens
/// are written there instead.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:async/async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:test_api/backend.dart';
import 'package:test_api/hooks.dart' show TestFailure;

import 'core.dart';
import 'guard.dart';
import 'junit.dart';

/// Runs [testMain] in-process and exits: 0 when every case passed or was
/// skipped, 1 otherwise. On SIGTERM it writes the report so far and exits 143.
///
/// [testFile] is the test's path under the runfiles root, which is also the
/// suite's path. [packageRoot] is the execroot path of the pubspec directory.
/// Stack paths under it are shown relative to it. [testLabel] is the test's
/// Bazel label, named in golden hints.
/// [goldensDeclared] is whether the test passes `goldens`, which picks the hint.
/// [metadataJson] is the library's parsed test metadata, as JSON.
void hostMain({
  required String testFile,
  required String packageRoot,
  required String testLabel,
  required bool goldensDeclared,
  required Future<void> Function() testMain,
  required String metadataJson,
}) {
  final env = Platform.environment;
  final runfiles = env['TEST_SRCDIR'] ?? env['RUNFILES_DIR'];
  if (runfiles == null) {
    throw StateError('TEST_SRCDIR or RUNFILES_DIR must be set');
  }
  // Bazel fails a test that exits 0 while this file exists. Only the driver's
  // own exits remove it, so a call to exit() in user code leaves it behind.
  final prematureExit = env['TEST_PREMATURE_EXIT_FILE'];
  if (prematureExit != null) File(prematureExit).writeAsStringSync('');

  final updateSource = env['FLUTTER_TEST_UPDATE_GOLDENS'];
  goldenFileComparator = _HostComparator(
    Uri.file(updateSource ?? '$runfiles/$testFile'),
    env['TEST_UNDECLARED_OUTPUTS_DIR'],
    testLabel,
    goldensDeclared: goldensDeclared,
    workspace: updateSource == null ? null : env['BUILD_WORKSPACE_DIRECTORY'],
  );
  autoUpdateGoldenFiles = updateSource != null;

  final only = env['TESTBRIDGE_TEST_ONLY'];
  final filter = only == null || only.isEmpty ? null : RegExp(only);

  Shard? shard;
  final total = env['TEST_TOTAL_SHARDS'];
  if (total != null) {
    final count = int.parse(total);
    final index = int.parse(env['TEST_SHARD_INDEX'] ?? '0');
    if (index < 0 || index >= count) {
      throw StateError('TEST_SHARD_INDEX $index is outside 0..${count - 1}');
    }
    shard = Shard(index, count);
    final status = env['TEST_SHARD_STATUS_FILE'];
    if (status != null) File(status).writeAsStringSync('');
  }

  final sink = _HostSink(packageRoot);
  final xmlPath = env['XML_OUTPUT_FILE'];
  // Errors raised after declaration, e.g. from a callback that outlives main.
  // The listener sends them after `success`, which the core ignores.
  final lateErrors = <CaseResult>[];
  final channel = RemoteListener.start(
    () =>
        () => guarded(testMain, lateErrors),
  );
  final os = _operatingSystem();

  // Set once the report is being written, so a SIGTERM during the final flush
  // cannot replace a complete report with an interrupted one.
  var finishing = false;
  // Handled only when the isolate yields. A busy loop is not interrupted.
  ProcessSignal.sigterm.watch().listen((_) {
    if (finishing) return;
    finishing = true;
    final running = sink.running ?? 'suite';
    _writeReport(xmlPath, testFile, [
      ...sink.results,
      CaseResult(
        running,
        Outcome.error,
        'interrupted by SIGTERM during $running',
      ),
    ], packageRoot);
    _exitAfterFlush(143);
  });

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
        nameFilter: filter,
        shard: shard,
        metadata: jsonDecode(metadataJson) as Map<String, Object?>,
      ),
      onComplete: (completed) {
        finishing = true;
        final cases = [...completed, ...lateErrors];
        for (final late in lateErrors) {
          sink.caseDone(late);
        }
        _writeReport(xmlPath, testFile, cases, packageRoot);
        final failed = cases.any(
          (c) => c.outcome == Outcome.fail || c.outcome == Outcome.error,
        );
        _exitAfterFlush(failed ? 1 : 0);
      },
    ),
  );
}

/// Writes the JUnit report to [path] through a temporary file, so that a
/// reader never sees a partial report.
void _writeReport(
  String? path,
  String suite,
  List<CaseResult> cases,
  String packageRoot,
) {
  if (path == null) return;
  final temp = File('$path.tmp')
    ..writeAsStringSync(junitReport(suite, cases, packageRoot));
  temp.renameSync(path);
}

/// Removes the premature-exit file, which marks this exit as deliberate, then
/// exits once stdout is flushed.
void _exitAfterFlush(int code) {
  final marker = Platform.environment['TEST_PREMATURE_EXIT_FILE'];
  if (marker != null && File(marker).existsSync()) File(marker).deleteSync();
  stdout.flush().whenComplete(() => exit(code));
}

String _operatingSystem() => switch (Platform.operatingSystem) {
  'macos' => 'mac-os',
  'windows' => 'windows',
  'linux' => 'linux',
  'android' => 'android',
  'ios' => 'ios',
  _ => 'none',
};

final class _HostSink implements EventSink {
  _HostSink(this._packageRoot);

  final String _packageRoot;

  /// Every finished case, in run order.
  final List<CaseResult> results = [];

  /// The case or hook running now. `load` until the suite has loaded.
  String? running = 'load';

  @override
  void message(String text) => stdout.writeln(displayPath(text, _packageRoot));

  @override
  void setRunning(String? name) => running = name;

  @override
  void caseDone(CaseResult result) {
    running = null;
    results.add(result);
    final label = switch (result.outcome) {
      Outcome.pass => 'PASS',
      Outcome.fail => 'FAIL',
      Outcome.error => 'ERROR',
      Outcome.skip => 'SKIP',
    };
    stdout.writeln('$label ${result.name}');
    if (result.message.isNotEmpty) {
      stdout.writeln(displayPath(result.message, _packageRoot));
    }
  }
}

/// Compares goldens against the test's runfiles. Failure images go under the
/// test's undeclared outputs. Updates are allowed only under the update target.
final class _HostComparator extends LocalFileComparator {
  _HostComparator(
    super.testFile,
    this._outputsDir,
    this._testLabel, {
    required bool goldensDeclared,
    required this.workspace,
  }) : _goldensDeclared = goldensDeclared;

  final String? _outputsDir;
  final String _testLabel;
  final bool _goldensDeclared;

  /// The workspace that updates are confined to. Null outside the update target.
  final String? workspace;

  @override
  File getFailureFile(String failure, Uri golden, Uri basedir) {
    final outputs = _outputsDir;
    if (outputs == null) {
      throw StateError('TEST_UNDECLARED_OUTPUTS_DIR must be set for failures');
    }
    final fileName = golden.pathSegments.last;
    final dot = fileName.lastIndexOf('.');
    final stem = dot < 0 ? fileName : fileName.substring(0, dot);
    return File('$outputs/failures/${stem}_$failure.png');
  }

  @override
  Future<List<int>> getGoldenBytes(Uri golden) async {
    try {
      return await super.getGoldenBytes(golden);
    } on TestFailure catch (failure) {
      final hint = _goldensDeclared
          ? 'declare it in `goldens` of $_testLabel and run '
                '`bazel run ${_testLabel}_update_goldens`'
          : 'declare it in `goldens` of $_testLabel (add `goldens = glob([...], '
                'allow_empty = True)` to create `${_testLabel}_update_goldens`)';
      throw TestFailure('$failure; $hint');
    }
  }

  @override
  Future<void> update(Uri golden, Uint8List imageBytes) {
    final root = workspace;
    if (root == null) {
      throw UnsupportedError(
        'Goldens are updated by `bazel run ${_testLabel}_update_goldens`: '
        '$golden',
      );
    }
    final target = basedir.resolveUri(golden);
    if (!target.path.startsWith(Directory(root).uri.path)) {
      throw UnsupportedError(
        'golden $golden resolves outside the workspace: $target',
      );
    }
    return super.update(golden, imageBytes);
  }
}
