/// Host driver: runs the suite in-process on flutter_tester, with the test's
/// runfiles and undeclared outputs.
///
/// The bootstrap (bootstrap.dart.tmpl) calls [hostMain]. Filters and shards
/// come from `TESTBRIDGE_TEST_ONLY` and `TEST_TOTAL_SHARDS`/`TEST_SHARD_INDEX`.
/// Goldens are compared, never updated.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:async/async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:test_api/backend.dart';

import 'core.dart';

/// Runs [testMain] in-process and exits: 0 when every case passed or was
/// skipped, 1 otherwise.
///
/// [testFile] is the test's path under the runfiles root, which is also the
/// suite's path and the golden comparator's base. [packageRoot] is the
/// execroot path of the pubspec directory. Stack paths under it are shown
/// relative to it.
void hostMain({
  required String testFile,
  required String packageRoot,
  required Future<void> Function() testMain,
}) {
  final env = Platform.environment;
  final runfiles = env['TEST_SRCDIR'] ?? env['RUNFILES_DIR'];
  if (runfiles == null) {
    throw StateError('TEST_SRCDIR or RUNFILES_DIR must be set');
  }
  goldenFileComparator = _HostComparator(
    Uri.file('$runfiles/$testFile'),
    env['TEST_UNDECLARED_OUTPUTS_DIR'],
  );

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
  // Errors raised after declaration, e.g. from a callback that outlives main.
  // The listener sends them after `success`, which the core ignores.
  final lateErrors = <CaseResult>[];
  final channel = RemoteListener.start(
    () =>
        () => _guarded(testMain, lateErrors),
  );
  final os = _operatingSystem();
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
      ),
      onComplete: (completed) {
        final cases = [...completed, ...lateErrors];
        for (final late in lateErrors) {
          sink.caseDone(late);
        }
        final xmlPath = env['XML_OUTPUT_FILE'];
        if (xmlPath != null) {
          File(xmlPath).writeAsStringSync(_junit(testFile, cases, packageRoot));
        }
        final failed = cases.any(
          (c) => c.outcome == Outcome.fail || c.outcome == Outcome.error,
        );
        stdout.flush().whenComplete(() => exit(failed ? 1 : 0));
      },
    ),
  );
}

/// Runs [body] in a zone. Errors while main is declaring go to the listener's
/// own zone. Later errors are recorded in [errors] as load failures, because
/// the listener sends them after `success`, which the core ignores.
Future<void> _guarded(
  Future<void> Function() body,
  List<CaseResult> errors,
) async {
  final outer = Zone.current;
  var declaring = true;
  try {
    await runZonedGuarded(body, (error, stack) {
      if (declaring) {
        outer.handleUncaughtError(error, stack);
      } else {
        errors.add(CaseResult('load', Outcome.error, '$error\n$stack'));
      }
    });
  } finally {
    declaring = false;
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

/// The error location as the user sees it. A tester stack names the
/// execroot-relative URI; the package part is cut so that a failure reads
/// `test/foo_test.dart:12`, and other files read as their execroot path.
String _display(String text, String packageRoot) => text
    .replaceAll('org-dartlang-root:///$packageRoot/', '')
    .replaceAll('org-dartlang-root:///', '');

final class _HostSink implements EventSink {
  _HostSink(this._packageRoot);

  final String _packageRoot;

  @override
  void message(String text) => stdout.writeln(_display(text, _packageRoot));

  @override
  void caseDone(CaseResult result) {
    final label = switch (result.outcome) {
      Outcome.pass => 'PASS',
      Outcome.fail => 'FAIL',
      Outcome.error => 'ERROR',
      Outcome.skip => 'SKIP',
    };
    stdout.writeln('$label ${result.name}');
    if (result.message.isNotEmpty) {
      stdout.writeln(_display(result.message, _packageRoot));
    }
  }
}

String _junit(String suite, List<CaseResult> cases, String packageRoot) {
  var failures = 0;
  var errors = 0;
  var skipped = 0;
  final body = StringBuffer();
  for (final result in cases) {
    final name = _xml(result.name);
    final classname = _xml(suite);
    final message = _xml(_display(result.message, packageRoot));
    final firstLine = _xml(
      _display(result.message, packageRoot).split('\n').first,
    );
    switch (result.outcome) {
      case Outcome.pass:
        body.write('<testcase classname="$classname" name="$name"/>');
      case Outcome.skip:
        skipped++;
        body.write(
          '<testcase classname="$classname" name="$name"><skipped/></testcase>',
        );
      case Outcome.fail:
        failures++;
        body.write(
          '<testcase classname="$classname" name="$name">'
          '<failure message="$firstLine">$message</failure></testcase>',
        );
      case Outcome.error:
        errors++;
        body.write(
          '<testcase classname="$classname" name="$name">'
          '<error message="$firstLine">$message</error></testcase>',
        );
    }
  }
  return '<?xml version="1.0" encoding="UTF-8"?>'
      '<testsuite name="${_xml(suite)}" tests="${cases.length}" '
      'failures="$failures" errors="$errors" skipped="$skipped">'
      '$body</testsuite>';
}

String _xml(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');

/// Compares goldens against the test's runfiles. Failure images go under the
/// test's undeclared outputs.
final class _HostComparator extends LocalFileComparator {
  _HostComparator(super.testFile, this._outputsDir);

  final String? _outputsDir;

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
  Future<void> update(Uri golden, Uint8List imageBytes) =>
      throw UnsupportedError(
        'Golden updates are not supported by the test driver: $golden',
      );
}
