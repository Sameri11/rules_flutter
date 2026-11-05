/// The device frame format, shared by the device driver, which writes it, and
/// the device decoder, which reads it back. No package imports.
///
/// A frame is one print line, `RFT|<run>|<seq>|<i>/<n>|<chunk>`, at most
/// [frameMaxChars] ASCII characters including the header. Event `seq` is a
/// zero-based contiguous number; its escaped JSON text is split into `n` chunks
/// that join in index order. The stream ends with `RFT_END|<run>|<status>`.
///
/// Payload characters at or below 0x20, at or above 0x7f, `%` and `\` are
/// written as `%uXXXX` (four hex digits of the UTF-16 code unit). Logcat and
/// os_log keep that text intact; a raw space or backslash is not reliable there.
///
/// Every chunk but the last of an event has exactly [chunkBudget] payload
/// characters for its run, sequence and count; the last is at most that long.
/// The decoder rejects a short non-final chunk, which catches a cut even where
/// the cut text would still parse. A strict prefix of a JSON object never
/// parses, so JSON parsing covers the final chunk.
library;

/// The frame prefix. It is public, so the protocol names no test-only label.
const String framePrefix = 'RFT';

const int frameMaxChars = 480;

/// The longest run id a frame may carry.
const int runIdMaxLength = 24;
final RegExp _runId = RegExp('^[A-Za-z0-9]{1,$runIdMaxLength}\$');
final RegExp _hex4 = RegExp(r'^[0-9a-fA-F]{4}$');

/// Whether [value] is a run identifier that a frame may carry.
bool isRunId(String value) => _runId.hasMatch(value);

/// The footer line that ends a stream.
String footerLine(String run, int status) => '${framePrefix}_END|$run|$status';

/// The header of frame [index] of [count] for event [seq], up to its chunk.
String frameHeader(String run, int seq, int index, int count) =>
    '$framePrefix|$run|$seq|$index/$count|';

/// The payload length of every chunk but the last of event [seq], split into
/// [count] chunks of [run]. The encoder splits by it and the decoder checks it.
int chunkBudget(String run, int seq, int count) =>
    frameMaxChars - frameHeader(run, seq, count - 1, count).length;

/// Whether [unit] may appear in a frame line outside an escape: printable ASCII
/// other than space and backslash. `%` is allowed here only as the start of an
/// escape, which [unescapePayload] checks once the chunks are joined.
bool isFrameUnit(int unit) => unit >= 0x21 && unit <= 0x7e && unit != 0x5c;

/// Escapes [text] for a frame.
String escapePayload(String text) {
  final out = StringBuffer();
  for (final unit in text.codeUnits) {
    if (unit <= 0x20 || unit >= 0x7f || unit == 0x25 || unit == 0x5c) {
      out.write('%u${unit.toRadixString(16).padLeft(4, '0')}');
    } else {
      out.writeCharCode(unit);
    }
  }
  return out.toString();
}

/// Reverses [escapePayload]. Throws [FormatException] on a malformed escape,
/// including a `%` that does not start `%uXXXX`.
String unescapePayload(String text) {
  final units = <int>[];
  var i = 0;
  while (i < text.length) {
    final unit = text.codeUnitAt(i);
    if (unit != 0x25) {
      units.add(unit);
      i++;
      continue;
    }
    final hex = i + 6 <= text.length && text.codeUnitAt(i + 1) == 0x75
        ? text.substring(i + 2, i + 6)
        : '';
    if (!_hex4.hasMatch(hex)) {
      throw FormatException('malformed escape at offset $i');
    }
    units.add(int.parse(hex, radix: 16));
    i += 6;
  }
  return String.fromCharCodes(units);
}

/// The frame lines that carry one event's [escaped] payload, each at most
/// [frameMaxChars] characters.
List<String> encodeEvent(String run, int seq, String escaped) {
  var count = 1;
  while (true) {
    final budget = chunkBudget(run, seq, count);
    if (budget <= 0) {
      throw StateError('frame header exceeds $frameMaxChars characters');
    }
    final needed = (escaped.length + budget - 1) ~/ budget;
    if (needed == count) break;
    count = needed;
  }
  final budget = chunkBudget(run, seq, count);
  final lines = <String>[];
  for (var i = 0; i < count; i++) {
    final start = i * budget;
    final end = start + budget < escaped.length
        ? start + budget
        : escaped.length;
    lines.add(frameHeader(run, seq, i, count) + escaped.substring(start, end));
  }
  return lines;
}
