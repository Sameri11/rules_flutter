/// The device run-settings file: the name filter, shard and run id the device
/// flavor applies. The file lives at [runSettingsPath] under
/// `Directory.systemTemp`. The runner writes it before every launch; the device
/// reads it once and deletes it, so a later launch never inherits it. A missing
/// file selects everything; any other problem is a failure, never a silent
/// fallback to the whole suite. No package imports.
library;

import 'dart:convert';

import 'frame.dart';

/// The settings file, relative to `Directory.systemTemp`.
const String runSettingsPath = 'rules_flutter_test/run_settings.json';

/// The outputs directory, relative to `Directory.systemTemp`. The device
/// empties it at the start of each run; the runner retrieves it into the
/// test's undeclared outputs.
const String outputsPath = 'rules_flutter_test/outputs';

const int _version = 1;

const Set<String> _keys = {
  'version',
  'nameFilter',
  'shardIndex',
  'shardCount',
  'runId',
};

/// What the settings file selects. A null [nameFilter] and [shardCount] select
/// everything; a null [runId] lets the device choose a random one.
final class RunSettings {
  const RunSettings({
    this.nameFilter,
    this.shardIndex,
    this.shardCount,
    this.runId,
  });

  /// The regular expression matched against full test names, or null.
  final String? nameFilter;

  /// The shard to run, 0-based, with [shardCount] shards; both set or both null.
  final int? shardIndex;
  final int? shardCount;

  /// The run id that prefixes every frame of this launch, or null.
  final String? runId;
}

/// Parses the settings file's UTF-8 [text]. Throws [FormatException] for
/// anything that cannot be applied exactly: invalid JSON, an unknown key, an
/// unsupported version, a regular expression that does not compile, a shard
/// outside `0..count-1`, or a run id that `isRunId` rejects.
///
/// The format is a JSON object: `version` (1), optional `nameFilter` (an empty
/// string selects everything), `shardIndex` with `shardCount` (given together),
/// and optional `runId`.
RunSettings parseRunSettings(String text) {
  final Object? json = jsonDecode(text);
  if (json is! Map<String, Object?>) {
    throw const FormatException('run settings must be a JSON object');
  }
  for (final key in json.keys) {
    if (!_keys.contains(key)) {
      throw FormatException('run settings has unknown key "$key"');
    }
  }
  if (json['version'] != _version) {
    throw FormatException(
      'run settings version must be $_version, not ${json['version']}',
    );
  }

  String? filter;
  if (json.containsKey('nameFilter')) {
    final value = json['nameFilter'];
    if (value is! String) {
      throw const FormatException('nameFilter must be a string');
    }
    if (value.isNotEmpty) {
      RegExp(value);
      filter = value;
    }
  }

  String? runId;
  if (json.containsKey('runId')) {
    final value = json['runId'];
    if (value is! String || !isRunId(value)) {
      throw FormatException(
        'runId must be 1 to $runIdMaxLength letters or digits',
      );
    }
    runId = value;
  }

  final hasIndex = json.containsKey('shardIndex');
  final hasCount = json.containsKey('shardCount');
  if (hasIndex != hasCount) {
    throw const FormatException(
      'shardIndex and shardCount must be set together',
    );
  }
  if (!hasIndex) {
    return RunSettings(nameFilter: filter, runId: runId);
  }
  final index = json['shardIndex'];
  final count = json['shardCount'];
  if (index is! int || count is! int) {
    throw const FormatException('shardIndex and shardCount must be integers');
  }
  if (count < 1 || index < 0 || index >= count) {
    throw FormatException('shard $index of $count is outside 0..${count - 1}');
  }
  return RunSettings(
    nameFilter: filter,
    shardIndex: index,
    shardCount: count,
    runId: runId,
  );
}

/// The run id that [text] names, when it names a valid one, else null. Reads
/// only `runId`, so the device can report a settings error under the id the
/// runner selects, even when the rest of the file is unusable.
String? runIdFromSettings(String? text) {
  if (text == null) return null;
  Object? json;
  try {
    json = jsonDecode(text);
  } on FormatException {
    return null;
  }
  if (json is! Map<String, Object?>) return null;
  final value = json['runId'];
  return value is String && isRunId(value) ? value : null;
}
