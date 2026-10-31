// Parses one test file's library-level annotations with test_core's parseMetadata.
//
// `dart parser.dill <display> <input> <output>`: the display name is the path in diagnostics.
// The output is a Dart library whose `testMetadataJson` is the Metadata.serialize() JSON as a
// string, which the test driver hands to the listener as its `initial` metadata. The dollar signs
// are escaped, so the literal is the JSON exactly. A parse error or a non-literal annotation exits
// 1 with the parser's message, which names the file and the source span.
import 'dart:convert';
import 'dart:io';

import 'package:test_core/src/runner/parse_metadata.dart';

void main(List<String> args) {
  if (args.length != 3) {
    stderr.writeln('usage: parser.dill <display> <input> <output>');
    exit(64);
  }
  final text = File(args[1]).readAsStringSync();
  final String json;
  try {
    json = jsonEncode(
      parseMetadata(args[0], text, const {'vm'}).serialize(),
    );
  } on Object catch (error) {
    stderr.writeln(error);
    exit(1);
  }
  final literal = jsonEncode(json).replaceAll(r'$', r'\$');
  File(args[2]).writeAsStringSync(
    '// Generated from ${args[0]} by flutter/private/test_metadata/parser.dart.\n'
    'const String testMetadataJson = $literal;\n',
  );
}
