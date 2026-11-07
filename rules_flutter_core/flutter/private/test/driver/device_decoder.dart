/// Decodes a captured device stream (logcat or os_log text) into the events of
/// one run and writes them as JUnit. Every check fails closed: a stream that is
/// truncated, incomplete, or inconsistent is an error, never a partial report.
///
/// Built from the declared toolchain as a kernel, so it imports nothing outside
/// this directory.
library;

import 'dart:convert';
import 'dart:io';

import 'frame.dart';
import 'junit.dart';
export 'junit.dart';
export 'results.dart';
import 'results.dart';

/// Malformed or inconsistent stream.
final class DecodeError implements Exception {
  DecodeError(this.message);

  final String message;

  @override
  String toString() => 'device stream: $message';
}

/// The transport layer's output: one payload per event, in sequence order.
final class Transport {
  Transport(this.run, this.status, this.payloads);

  final String run;

  /// The footer status: 0 for success, 1 for any failed or errored case.
  final int status;

  /// Unescaped payload text of each event, in sequence order.
  final List<String> payloads;
}

/// The decoded run: its cases in run order and the footer status.
final class DecodedRun {
  DecodedRun(this.run, this.status, this.cases);

  final String run;
  final int status;
  final List<CaseResult> cases;
}

final RegExp _seqField = RegExp(r'^(0|[1-9][0-9]{0,8})$');
final RegExp _indexField = RegExp(r'^(0|[1-9][0-9]{0,8})/([1-9][0-9]{0,8})$');
final RegExp _markerPattern = RegExp(r'RFT(_END)?\|');

/// Reassembles the frames of [text] into payloads. [run] selects the run; when
/// null, the stream must carry exactly one run.
Transport decodeTransport(String text, {String? run}) {
  final lines = text.split('\n');
  final candidates = <String>{};
  for (final raw in lines) {
    final line = raw.endsWith('\r') ? raw.substring(0, raw.length - 1) : raw;
    final match = _markerPattern.firstMatch(line);
    if (match == null) continue;
    final body = line.substring(match.end);
    final field = body.split('|').first;
    if (isRunId(field)) candidates.add(field);
  }
  final selected = run ?? _onlyRun(candidates);

  final groups = <int, _Event>{};
  final footers = <int>{};
  for (final raw in lines) {
    final line = raw.endsWith('\r') ? raw.substring(0, raw.length - 1) : raw;
    final match = _markerPattern.firstMatch(line);
    if (match == null) continue;
    final framed = line.substring(match.start);
    final body = framed.substring(match.end - match.start);
    final fields = body.split('|');
    // Frames of other runs, and noise, are not this run's to validate.
    if (fields.first != selected) continue;
    if (framed.length > frameMaxChars) {
      throw DecodeError('frame longer than $frameMaxChars characters');
    }
    for (final unit in framed.codeUnits) {
      if (!isFrameUnit(unit)) {
        throw DecodeError('frame contains a character outside the frame set');
      }
    }

    if (match.group(1) != null) {
      if (fields.length != 2 || !_isStatus(fields[1])) {
        throw DecodeError('malformed footer: $framed');
      }
      footers.add(int.parse(fields[1]));
      continue;
    }

    if (fields.length < 4) {
      throw DecodeError('malformed frame: $framed');
    }
    final seqText = fields[1];
    final indexText = fields[2];
    final chunk = fields.sublist(3).join('|');
    if (!_seqField.hasMatch(seqText)) {
      throw DecodeError('malformed sequence number: $framed');
    }
    final index = _indexField.firstMatch(indexText);
    if (index == null) {
      throw DecodeError('malformed chunk index: $framed');
    }
    final i = int.parse(index.group(1)!);
    final n = int.parse(index.group(2)!);
    if (i >= n) {
      throw DecodeError('chunk index $i is outside 0..${n - 1}');
    }
    if (chunk.isEmpty) {
      throw DecodeError('empty chunk: $framed');
    }
    final seq = int.parse(seqText);
    // Every chunk but the last is the encoder's full budget; a short one was cut.
    if (i < n - 1 && chunk.length != chunkBudget(selected, seq, n)) {
      throw DecodeError(
        'chunk $i of event $seq is ${chunk.length} characters, '
        'not ${chunkBudget(selected, seq, n)}',
      );
    }
    final event = groups.putIfAbsent(seq, () => _Event(n));
    if (event.count != n) {
      throw DecodeError('event $seq disagrees on its chunk count');
    }
    final existing = event.chunks[i];
    if (existing != null) {
      if (existing != chunk) {
        throw DecodeError('conflicting duplicate of event $seq chunk $i');
      }
      continue;
    }
    event.chunks[i] = chunk;
  }

  if (footers.isEmpty) {
    throw DecodeError('missing footer');
  }
  if (footers.length > 1) {
    throw DecodeError('footers disagree on status');
  }
  if (groups.isEmpty) {
    throw DecodeError('no frames for run $selected');
  }
  final seqs = groups.keys.toList()..sort();
  for (var k = 0; k < seqs.length; k++) {
    if (seqs[k] != k) {
      throw DecodeError('event sequence has a gap at $k');
    }
  }

  final payloads = <String>[];
  for (final seq in seqs) {
    final event = groups[seq]!;
    final joined = StringBuffer();
    for (var i = 0; i < event.count; i++) {
      final chunk = event.chunks[i];
      if (chunk == null) {
        throw DecodeError('event $seq is missing chunk $i');
      }
      joined.write(chunk);
    }
    try {
      payloads.add(unescapePayload(joined.toString()));
    } on FormatException catch (error) {
      throw DecodeError('event $seq: ${error.message}');
    }
  }
  return Transport(selected, footers.single, payloads);
}

/// Decodes a complete stream: transport, then the event sequence, then the
/// consistency checks against the footer.
DecodedRun decodeStream(String text, {String? run}) {
  final transport = decodeTransport(text, run: run);
  final cases = <CaseResult>[];
  var complete = 0;
  Map<String, Object?>? completeEvent;
  for (var seq = 0; seq < transport.payloads.length; seq++) {
    final event = _parseEvent(transport.payloads[seq], transport.run, seq);
    switch (event['type']) {
      case 'message' || 'running':
        break;
      case 'case':
        cases.add(_caseResult(event));
      case 'complete':
        complete++;
        completeEvent = event;
        if (seq != transport.payloads.length - 1) {
          throw DecodeError('complete event is not the last event');
        }
    }
  }
  if (complete != 1 || completeEvent == null) {
    throw DecodeError('expected exactly one complete event, found $complete');
  }
  final expectedStatus =
      cases.any((c) => c.outcome == Outcome.fail || c.outcome == Outcome.error)
      ? 1
      : 0;
  if (completeEvent['caseCount'] != cases.length) {
    throw DecodeError(
      'complete event reports ${completeEvent['caseCount']} cases, '
      'decoded ${cases.length}',
    );
  }
  if (completeEvent['status'] != transport.status ||
      transport.status != expectedStatus) {
    throw DecodeError(
      'status disagrees: footer ${transport.status}, '
      'complete ${completeEvent['status']}, cases $expectedStatus',
    );
  }
  return DecodedRun(transport.run, transport.status, cases);
}

Map<String, Object?> _parseEvent(String payload, String run, int seq) {
  final Object? json;
  try {
    json = jsonDecode(payload);
  } on FormatException {
    throw DecodeError('event $seq is not JSON');
  }
  if (json is! Map<String, Object?>) {
    throw DecodeError('event $seq is not an object');
  }
  if (json['run'] != run) {
    throw DecodeError('event $seq belongs to another run');
  }
  if (json['seq'] is! int || json['seq'] != seq) {
    throw DecodeError('event $seq carries sequence ${json['seq']}');
  }
  final Set<String> keys;
  switch (json['type']) {
    case 'message':
      keys = {'text'};
      if (json['text'] is! String) throw _shape(seq);
    case 'running':
      keys = {'name'};
      if (json['name'] != null && json['name'] is! String) throw _shape(seq);
    case 'case':
      keys = {'name', 'outcome', 'message', 'tags'};
      if (json['name'] is! String ||
          json['message'] is! String ||
          !_outcomes.contains(json['outcome']) ||
          !_isTagList(json['tags'])) {
        throw _shape(seq);
      }
    case 'complete':
      keys = {'caseCount', 'status'};
      if (json['caseCount'] is! int || json['status'] is! int) {
        throw _shape(seq);
      }
    default:
      throw DecodeError('event $seq has an unknown type');
  }
  final expected = {'run', 'seq', 'type', ...keys};
  if (json.keys.toSet().difference(expected).isNotEmpty ||
      expected.difference(json.keys.toSet()).isNotEmpty) {
    throw _shape(seq);
  }
  return json;
}

DecodeError _shape(int seq) => DecodeError('event $seq has the wrong shape');

const Set<String> _outcomes = {'pass', 'fail', 'skip', 'error'};

bool _isTagList(Object? value) =>
    value is List && value.every((tag) => tag is String);

CaseResult _caseResult(Map<String, Object?> event) => CaseResult(
  event['name']! as String,
  Outcome.values.byName(event['outcome']! as String),
  event['message']! as String,
  List<String>.from(event['tags']! as List),
);

bool _isStatus(String text) => text == '0' || text == '1';

String _onlyRun(Set<String> candidates) {
  if (candidates.length != 1) {
    throw DecodeError(
      'expected one run in the stream, found ${candidates.length}',
    );
  }
  return candidates.single;
}

final class _Event {
  _Event(this.count);

  final int count;
  final Map<int, String> chunks = {};
}

void main(List<String> args) {
  String? run;
  String? xmlPath;
  String? transportPath;
  String? suite;
  String? input;
  for (var k = 0; k < args.length; k++) {
    final arg = args[k];
    String value() {
      if (k + 1 >= args.length) {
        stderr.writeln('device decoder: $arg needs a value');
        exit(2);
      }
      return args[++k];
    }

    switch (arg) {
      case '--run':
        run = value();
      case '--xml':
        xmlPath = value();
      case '--transport':
        transportPath = value();
      case '--suite':
        suite = value();
      default:
        if (input != null) {
          stderr.writeln('device decoder: one input file expected');
          exit(2);
        }
        input = arg;
    }
  }
  if (input == null) {
    stderr.writeln(
      'usage: device_decoder [--run ID] [--suite NAME] [--xml OUT] '
      '[--transport OUT] INPUT',
    );
    exit(2);
  }
  final text = File(input).readAsStringSync();
  try {
    if (transportPath != null) {
      final transport = decodeTransport(text, run: run);
      File(transportPath).writeAsStringSync(transport.payloads.join());
      return;
    }
    final decoded = decodeStream(text, run: run);
    if (xmlPath != null) {
      File(xmlPath)
          .writeAsStringSync(junitReport(suite ?? 'device', decoded.cases, ''));
    }
    exit(decoded.status);
  } on DecodeError catch (error) {
    stderr.writeln(error);
    exit(2);
  }
}
