/// Tests for the device frame codec, the decoder, and the run settings parser.
///
/// Run with the directory of the fixtures as the only argument. Plain Dart: it
/// imports the driver files directly and needs no packages.
library;

import 'dart:convert';
import 'dart:io';

import '../../flutter/private/test/driver/device_decoder.dart';
import '../../flutter/private/test/driver/frame.dart';
import '../../flutter/private/test/driver/results.dart';
import '../../flutter/private/test/driver/settings.dart';

const String _run = 'hnae8zewva7dlp0';
int _failures = 0;

void check(String name, void Function() body) {
  try {
    body();
    stdout.writeln('PASS $name');
  } on Object catch (error) {
    _failures++;
    stdout.writeln('FAIL $name: $error');
  }
}

void expect(bool condition, String what) {
  if (!condition) throw StateError(what);
}

void rejects(String name, Object stream, {String? run}) => check(name, () {
  final text = stream is List<String> ? stream.join('\n') : stream as String;
  try {
    decodeStream(text, run: run);
  } on DecodeError {
    return;
  }
  throw StateError('stream was accepted');
});

/// Builds a complete stream of [payloads] (event JSON texts) for [run].
String buildStream(String run, List<String> payloads, int status) {
  final lines = <String>[];
  for (var seq = 0; seq < payloads.length; seq++) {
    lines.addAll(encodeEvent(run, seq, escapePayload(payloads[seq])));
  }
  lines.add(footerLine(run, status));
  return lines.join('\n');
}

int indexWhere(List<String> lines, bool Function(String) test) {
  final index = lines.indexWhere(test);
  expect(index >= 0, 'fixture line not found');
  return index;
}

/// [lines] with line [index] replaced by [change] of it, joined with newlines.
String withLine(List<String> lines, int index, String Function(String) change) {
  final edited = [...lines];
  edited[index] = change(lines[index]);
  return edited.join('\n');
}

String _caseJson(List<String> tags) => jsonEncode({
  'run': _run,
  'seq': 0,
  'type': 'case',
  'name': 'n',
  'outcome': 'pass',
  'message': '',
  'tags': tags,
});

String _completeJson(int seq) => jsonEncode({
  'run': _run,
  'seq': seq,
  'type': 'complete',
  'caseCount': 1,
  'status': 0,
});

void main(List<String> args) {
  final dir = args.single;
  final logcat = File('$dir/logcat_events.txt').readAsStringSync();
  final lines = logcat.split('\n');
  final payloads = decodeTransport(logcat).payloads;
  final status = decodeTransport(logcat).status;

  // The multi-chunk message event is sequence 1 with four chunks.
  final multiChunk = indexWhere(lines, (l) => l.contains('|1/4|'));

  check('baseline decodes to one passing case', () {
    final run = decodeStream(logcat);
    expect(run.cases.length == 1, 'cases ${run.cases.length}');
    expect(run.cases.single.outcome == Outcome.pass, 'outcome');
    expect(run.cases.single.name.contains('pass'), 'name');
    expect(run.status == 0, 'status');
  });

  check('reordered frames are accepted', () {
    final reversed = lines.reversed.join('\n');
    expect(
      decodeStream(reversed, run: _run).cases.single.name ==
          decodeStream(logcat).cases.single.name,
      'reordered result differs',
    );
  });

  check('identical duplicate frame is accepted', () {
    final duplicated = [...lines]..insert(multiChunk, lines[multiChunk]);
    expect(
      decodeStream(duplicated.join('\n')).cases.length == 1,
      'duplicate changed result',
    );
  });

  check('noise and another run are ignored when a run is selected', () {
    final other = buildStream('zzzz9', ['{}'], 0).split('\n');
    final mixed = [
      'I/flutter (1): unrelated line',
      ...lines.take(3),
      ...other,
      ...lines.skip(3),
    ].join('\n');
    expect(
      decodeStream(mixed, run: _run).cases.length == 1,
      'noise changed result',
    );
  });

  // The footer stays, so the stream looks complete and only the frame is cut.
  final lastEvent = lines.lastIndexWhere(
    (l) => l.contains('RFT|') && !l.contains('RFT_END|'),
  );
  expect(lastEvent >= 0, 'fixture has no event frame');
  rejects(
    'truncated last event frame is rejected',
    withLine(lines, lastEvent, (l) => l.substring(0, l.length - 3)),
    run: _run,
  );
  rejects(
    'truncated non-final chunk is rejected',
    withLine(lines, multiChunk, (l) => l.substring(0, l.length - 3)),
    run: _run,
  );

  check('non-final chunks have the shared budget length', () {
    final frames = encodeEvent(_run, 0, escapePayload('x' * 3000));
    final count = frames.length;
    expect(count > 2, 'event did not split: $count frames');
    for (var i = 0; i < count - 1; i++) {
      final chunk = frames[i].substring(frameHeader(_run, 0, i, count).length);
      expect(
        chunk.length == chunkBudget(_run, 0, count),
        'chunk $i has ${chunk.length} characters',
      );
    }
  });

  check('case tags are decoded', () {
    final stream = buildStream(_run, [
      _caseJson(['conformance-tag']),
      _completeJson(1),
    ], 0);
    expect(
      decodeStream(stream, run: _run).cases.single.tags.single ==
          'conformance-tag',
      'tags were not decoded',
    );
  });
  rejects(
    'case event without tags is rejected',
    buildStream(_run, [
      '{"run":"$_run","seq":0,"type":"case","name":"n","outcome":"pass","message":""}',
      _completeJson(1),
    ], 0),
    run: _run,
  );
  rejects(
    'case tags that are not strings are rejected',
    buildStream(_run, [
      '{"run":"$_run","seq":0,"type":"case","name":"n","outcome":"pass","message":"","tags":[1]}',
      _completeJson(1),
    ], 0),
    run: _run,
  );

  check('frames of another run are not validated', () {
    final mixed = [
      ...lines.take(3),
      'I/flutter (1): RFT|zzzz9|0|bad|a b c',
      ...lines.skip(3),
    ].join('\n');
    expect(
      decodeStream(mixed, run: _run).cases.length == 1,
      'other run changed result',
    );
  });

  check('run settings accept a run id and reject a bad one', () {
    expect(
      parseRunSettings('{"version":1,"runId":"abc1"}').runId == 'abc1',
      'runId',
    );
    for (final text in [
      '{"version":1,"runId":"ABC"}',
      '{"version":1,"runId":""}',
      '{"version":1,"runId":5}',
    ]) {
      var rejected = false;
      try {
        parseRunSettings(text);
      } on FormatException {
        rejected = true;
      }
      expect(rejected, 'accepted $text');
    }
  });

  rejects(
    'missing footer is rejected',
    lines.where((l) => !l.contains('RFT_END|')).join('\n'),
    run: _run,
  );

  rejects(
    'dropped multi-part chunk is rejected',
    lines.where((l) => !l.contains('|1/4|')).join('\n'),
    run: _run,
  );

  rejects(
    'dropped whole event is rejected',
    lines.where((l) => !l.contains('RFT|$_run|1|')).join('\n'),
    run: _run,
  );

  rejects(
    'dropped complete event is rejected',
    buildStream(_run, payloads.take(payloads.length - 1).toList(), status),
    run: _run,
  );

  rejects(
    'conflicting duplicate is rejected',
    [...lines]
      ..insert(multiChunk, lines[multiChunk].replaceFirst('xxxx', 'yyyy')),
    run: _run,
  );

  rejects(
    'wrong footer status is rejected',
    buildStream(_run, payloads, 1),
    run: _run,
  );

  rejects(
    'overlong frame is rejected',
    [...lines]..[multiChunk] = '${lines[multiChunk]}x',
    run: _run,
  );

  rejects(
    'non-ASCII frame is rejected',
    [...lines]
      ..[multiChunk] = lines[multiChunk].replaceFirst('xxxx', 'caf\u00e9'),
    run: _run,
  );

  rejects(
    'space in a frame is rejected',
    [...lines]..[multiChunk] = lines[multiChunk].replaceFirst('xxxx', 'a b'),
    run: _run,
  );

  check('wrong case count is rejected', () {
    final complete = jsonDecode(payloads.last) as Map<String, Object?>;
    complete['caseCount'] = 2;
    final altered = [...payloads]..[payloads.length - 1] = jsonEncode(complete);
    try {
      decodeStream(buildStream(_run, altered, status), run: _run);
    } on DecodeError {
      return;
    }
    throw StateError('stream was accepted');
  });

  check('boolean sequence number is rejected', () {
    final event = jsonDecode(payloads.first) as Map<String, Object?>;
    event['seq'] = true;
    final altered = [...payloads]..[0] = jsonEncode(event);
    try {
      decodeStream(buildStream(_run, altered, status), run: _run);
    } on DecodeError {
      return;
    }
    throw StateError('stream was accepted');
  });

  check('valid JSON alteration is accepted: no checksum boundary', () {
    final index = payloads.indexWhere((p) => p.contains('"type":"case"'));
    final event = jsonDecode(payloads[index]) as Map<String, Object?>;
    event['name'] = 'altered name';
    final altered = [...payloads]..[index] = jsonEncode(event);
    final run = decodeStream(buildStream(_run, altered, status), run: _run);
    expect(run.cases.single.name == 'altered name', 'name not altered');
  });

  check('unicode, space, percent and backslash payload round-trips', () {
    const text = 'unicode \u{1F600} caf\u00e9 100% \\ "q" \n\t';
    expect(unescapePayload(escapePayload(text)) == text, 'round trip');
    final frames = encodeEvent(_run, 0, escapePayload(text));
    for (final frame in frames) {
      expect(frame.length <= frameMaxChars, 'frame over $frameMaxChars');
      for (final unit in frame.codeUnits) {
        expect(isFrameUnit(unit) || unit == 0x7c, 'frame unit $unit');
      }
    }
  });

  check('long event splits into frames and decodes back exactly', () {
    final message = jsonEncode({
      'run': _run,
      'seq': 0,
      'type': 'message',
      'text': 'x' * 5000 + ' \u{1F600} 100%',
    });
    final transport = decodeTransport(buildStream(_run, [message], 0));
    expect(transport.payloads.single == message, 'payload changed');
  });

  check('captured large logcat stream reassembles', () {
    final text = File('$dir/logcat_large.txt').readAsStringSync();
    final transport = decodeTransport(text);
    expect(transport.payloads.length == 1, 'one event');
    expect(escapePayload(transport.payloads.single).length == 92413, 'length');
    expect(transport.payloads.single.startsWith('unicode '), 'start');
  });

  check('captured large os_log stream reassembles', () {
    final text = File('$dir/oslog_large.txt').readAsStringSync();
    final transport = decodeTransport(text);
    expect(transport.payloads.length == 1, 'one event');
    expect(escapePayload(transport.payloads.single).length == 92413, 'length');
    expect(transport.payloads.single.startsWith('unicode '), 'start');
  });

  check('settings: valid selections parse', () {
    final filtered = parseRunSettings('{"version":1,"nameFilter":"beta"}');
    expect(filtered.nameFilter == 'beta', 'filter');
    expect(filtered.shardCount == null, 'no shard');
    final sharded = parseRunSettings(
      '{"version":1,"nameFilter":"","shardIndex":1,"shardCount":3}',
    );
    expect(sharded.nameFilter == null, 'empty filter selects all');
    expect(sharded.shardIndex == 1 && sharded.shardCount == 3, 'shard');
  });

  for (final entry in {
    'invalid regex': '{"version":1,"nameFilter":"("}',
    'shard index past count': '{"version":1,"shardIndex":3,"shardCount":3}',
    'zero shard count': '{"version":1,"shardIndex":0,"shardCount":0}',
    'index without count': '{"version":1,"shardIndex":0}',
    'unknown key': '{"version":1,"color":"red"}',
    'missing version': '{"nameFilter":"a"}',
    'unsupported version': '{"version":2}',
    'not an object': '[1]',
  }.entries) {
    check('settings rejects ${entry.key}', () {
      try {
        parseRunSettings(entry.value);
      } on FormatException {
        return;
      }
      throw StateError('settings were accepted');
    });
  }

  if (_failures > 0) {
    stdout.writeln('$_failures failed');
    exit(1);
  }
  stdout.writeln('all passed');
}
