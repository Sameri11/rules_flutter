/// Result types shared by the driver core, the host and device flavors, and
/// the device decoder. No package imports, so the decoder compiles from these
/// files alone.
library;

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
