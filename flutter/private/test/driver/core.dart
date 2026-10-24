/// Runs one test suite over a RemoteListener channel and reports each case to
/// an [EventSink]. It never reads the environment or calls `exit()`: the host
/// driver supplies the platform, name filter, shard, sink and completion
/// callback.
library;

import 'dart:async';

import 'package:async/async.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test_api/backend.dart';

/// The result of one case. [name] is the full test name, or `load` for a suite
/// that failed to load. [tags] are the case's tags, inherited from its library
/// and groups.
final class CaseResult {
  const CaseResult(
    this.name,
    this.outcome, [
    this.message = '',
    this.tags = const <String>[],
  ]);

  final String name;
  final Outcome outcome;

  /// Failure, error or skip text, one entry per error event. A skip carries its
  /// reason here; otherwise empty.
  final String message;

  final List<String> tags;
}

enum Outcome { pass, fail, skip, error }

abstract interface class EventSink {
  /// Text from a test or from the suite load, in the order it was printed.
  void message(String text);

  /// The case or hook named [name] starts running, or nothing does when null.
  void setRunning(String? name);

  /// A case has finished. Called in run order.
  void caseDone(CaseResult result);
}

/// Shard [index] of [count], 0-based.
final class Shard {
  const Shard(this.index, this.count);

  final int index;
  final int count;
}

final class CoreOptions {
  const CoreOptions({
    required this.platform,
    required this.platformVariables,
    required this.suitePath,
    required this.sink,
    required this.metadata,
    this.nameFilter,
    this.shard,
  });

  /// A `SuitePlatform.serialize()` map: `runtime`, `compiler`, `os`, `inGoogle`.
  final Map<String, Object> platform;
  final List<String> platformVariables;
  final String suitePath;
  final EventSink sink;

  /// The library's `Metadata.serialize()` map: the annotations of the test file,
  /// which the listener applies to the suite and inherits into every case.
  final Map<String, Object?> metadata;

  /// Matched against full test names, as `flutter test --name` does.
  final RegExp? nameFilter;
  final Shard? shard;
}

/// Runs the suite behind [channel] and reports every case to [onComplete].
///
/// [onComplete] runs once, after the last case, with the cases in run order;
/// the caller writes its reports and exits there.
Future<void> runCore(
  StreamChannel<Object?> channel,
  CoreOptions options, {
  required void Function(List<CaseResult> cases) onComplete,
}) async {
  final core = _Core(channel, options);
  await core.run();
  onComplete(List.unmodifiable(core.cases));
}

const _spawnHybrid = 'spawn-hybrid-uri';

final class _Core {
  _Core(StreamChannel<Object?> channel, this.options)
    : _multi = MultiChannel<Object?>(channel),
      _suitePlatform = SuitePlatform.deserialize(options.platform);

  final CoreOptions options;
  final MultiChannel<Object?> _multi;
  final SuitePlatform _suitePlatform;
  final cases = <CaseResult>[];

  /// Root-channel messages that arrive during a run. They fail the running case.
  final _strays = StreamController<Object?>.broadcast(sync: true);

  /// The leaves that run, by identity. Filled once the suite has loaded.
  Set<Map> _chosen = Set.identity();

  void _finish(CaseResult result) {
    cases.add(result);
    options.sink.caseDone(result);
  }

  Future<void> run() async {
    final input = StreamQueue<Object?>(_multi.stream);
    _multi.sink.add({
      'type': 'initial',
      'platform': options.platform,
      'metadata': {...options.metadata, 'testOn': null},
      'asciiGlyphs': false,
      'path': options.suitePath,
      'collectTraces': true,
      'noRetry': false,
      'foldTraceExcept': <String>[],
      'foldTraceOnly': <String>[],
      'allowDuplicateTestNames': true,
      'ignoreTimeouts': false,
      'platformVariables': options.platformVariables,
    });
    final response = await _nextResponse(input);
    if (response == null) {
      _finish(
        const CaseResult(
          'load',
          Outcome.error,
          'the listener closed before it reported the suite',
        ),
      );
    } else if (response['type'] == 'loadException' ||
        response['type'] == 'error') {
      _finish(CaseResult('load', Outcome.error, _describe(response)));
    } else if (response['type'] != 'success') {
      _finish(
        CaseResult(
          'load',
          Outcome.error,
          'unexpected remote response: $response',
        ),
      );
    } else {
      final root = response['root'] as Map;
      _choose(root);
      input.rest.listen((message) {
        if (message is Map &&
            message['type'] != 'print' &&
            message['type'] != 'error') {
          _strays.add(message);
        }
      });
      await _visit(root, skipReason: _libraryReason(options.metadata));
    }
  }

  Future<Map?> _nextResponse(StreamQueue<Object?> input) async {
    while (await input.hasNext) {
      final message = await input.next as Map;
      if (message['type'] == 'print') {
        options.sink.message(message['line'] as String);
      } else {
        return message;
      }
    }
    return null;
  }

  /// Chooses the leaves to run: the name filter first, then the shard slice in
  /// declaration order. The slice formula is test_core's (runner.dart:574-578),
  /// so `flutter test --total-shards/--shard-index` selects the same tests.
  void _choose(Map root) {
    final filter = options.nameFilter;
    final leaves = <Map>[];
    void collect(Map group) {
      for (final entry in group['entries'] as List) {
        if (entry['type'] == 'group') {
          collect(entry as Map);
        } else {
          final item = entry as Map;
          if (filter == null || filter.hasMatch(item['name'] as String)) {
            leaves.add(item);
          }
        }
      }
    }

    collect(root);
    var selected = leaves;
    final shard = options.shard;
    if (shard != null) {
      final size = leaves.length / shard.count;
      final start = (size * shard.index).round();
      final end = (size * (shard.index + 1)).round();
      selected = leaves.sublist(start, end);
    }
    _chosen = Set.identity()..addAll(selected);
  }

  bool _supports(Map metadata) {
    final selector = metadata['testOn'];
    return selector == null ||
        PlatformSelector.parse(selector as String).evaluate(_suitePlatform);
  }

  /// The reason every case of the library is skipped, or null when it runs. The
  /// listener drops a group whose `testOn` fails, which would leave an empty
  /// suite. run() therefore strips the library's `testOn` from `initial`, and
  /// this check applies it, with the library's own `skip`.
  String? _libraryReason(Map metadata) {
    final selector = metadata['testOn'];
    if (selector != null &&
        !PlatformSelector.parse(selector as String).evaluate(_suitePlatform)) {
      return 'not compatible with ${_suitePlatform.runtime.identifier}';
    }
    return _skipOf(metadata);
  }

  /// The reason a group or test is skipped by its own metadata, or null.
  String? _skipOf(Map metadata) {
    if (metadata['skip'] != true) return null;
    return (metadata['skipReason'] as String?) ?? '';
  }

  /// Whether any chosen leaf lies under [group]. A group without one is not
  /// entered, so its setUpAll and tearDownAll do not run.
  bool _hasChosen(Map group) {
    for (final entry in group['entries'] as List) {
      if (entry['type'] == 'group') {
        if (_hasChosen(entry as Map)) return true;
      } else if (_chosen.contains(entry)) {
        return true;
      }
    }
    return false;
  }

  /// Runs the chosen cases of [group]. A skipped group, with [skipReason] or its
  /// own skip, runs no setUpAll or tearDownAll, and its cases report as skipped.
  Future<void> _visit(Map group, {String? skipReason}) async {
    if (!_hasChosen(group)) return;
    final reason = skipReason ?? _skipOf(group['metadata'] as Map);
    var setUpOk = true;
    if (reason == null) {
      setUpOk = await _runHook(group['setUpAll'] as Map?);
    }
    if (setUpOk) {
      for (final entry in group['entries'] as List) {
        if (entry['type'] == 'group') {
          await _visit(entry as Map, skipReason: reason);
        } else if (_chosen.contains(entry)) {
          await _runTest(entry as Map, skipReason: reason);
        }
      }
    }
    if (reason == null) {
      await _runHook(group['tearDownAll'] as Map?);
    }
  }

  /// Runs a setUpAll or tearDownAll under the name test_api gives it. Reports a
  /// case only on failure, as the `flutter test` reporter does. Returns whether
  /// it succeeded.
  Future<bool> _runHook(Map? hook) async {
    if (hook == null) return true;
    final name = hook['name'] as String;
    final tests = _multi.virtualChannel((hook['channel'] as num).toInt());
    final run = tests.virtualChannel();
    options.sink.setRunning(name);
    tests.sink.add({'command': 'run', 'channel': run.id});
    final outcome = await _drain(run.stream, name);
    if (outcome.result == 'success') {
      options.sink.setRunning(null);
      return true;
    }
    _finish(CaseResult(name, _outcomeOf(outcome.result), outcome.detail));
    return false;
  }

  Future<void> _runTest(Map item, {String? skipReason}) async {
    final name = item['name'] as String;
    final metadata = item['metadata'] as Map;
    final tags = (metadata['tags'] as List).cast<String>();
    final reason = skipReason ?? _skipOf(metadata);
    if (reason != null) {
      _finish(CaseResult(name, Outcome.skip, reason, tags));
      return;
    }
    final tests = _multi.virtualChannel((item['channel'] as num).toInt());
    // The listener owns retries (test_api's Invoker runs metadata.retry extra
    // attempts and prints `Retry:`), as the CLI does. One run per case here.
    final run = tests.virtualChannel();
    options.sink.setRunning(name);
    tests.sink.add({'command': 'run', 'channel': run.id});
    final outcome = await _drain(run.stream, name);
    switch (outcome.result) {
      case 'success':
        _finish(CaseResult(name, Outcome.pass, '', tags));
      case 'skipped':
        _finish(CaseResult(name, Outcome.skip, '', tags));
      default:
        _finish(
          CaseResult(name, _outcomeOf(outcome.result), outcome.detail, tags),
        );
    }
  }

  /// Reads one run to completion. Stops at `spawnHybridUri`, which the tester
  /// cannot serve, so the case fails now instead of waiting forever. A message
  /// of an unknown type fails the case, and the run is still read to `complete`
  /// so that the next case starts only after this one ends.
  Future<_Drained> _drain(Stream<Object?> stream, String name) async {
    final queue = StreamQueue<Object?>(
      StreamGroup.merge<Object?>([stream, _strays.stream]),
    );
    final detail = StringBuffer();
    var result = 'success';
    var unsupported = false;
    try {
      while (await queue.hasNext) {
        final message = await queue.next as Map;
        switch (message['type']) {
          case 'error':
            detail.writeln(_describe(message));
          case 'message':
            options.sink.message(message['text'] as String);
          case 'state-change':
            result = message['result'] as String;
          case _spawnHybrid:
            detail.writeln(
              'spawnHybridUri is not supported under flutter_tester: '
              '${message['uri']}',
            );
            return _Drained(_spawnHybrid, detail.toString());
          case 'complete':
            return _Drained(unsupported ? 'error' : result, detail.toString());
          default:
            unsupported = true;
            detail.writeln(
              'unsupported test channel message: ${message['type']}',
            );
        }
      }
      return _Drained(unsupported ? 'error' : result, detail.toString());
    } finally {
      await queue.cancel();
    }
  }

  static Outcome _outcomeOf(String result) =>
      result == 'error' ? Outcome.error : Outcome.fail;

  static String _describe(Map message) {
    final value = message['type'] == 'loadException'
        ? message['message']
        : message['error'];
    if (value is! Map) return '$value';
    final text = value['message'] ?? value['toString'] ?? value['type'];
    final stack = value['stackChain'];
    return stack == null || stack == '' ? '$text' : '$text\n$stack';
  }
}

final class _Drained {
  const _Drained(this.result, this.detail);

  /// The last state-change result, or `spawn-hybrid-uri`.
  final String result;
  final String detail;
}
