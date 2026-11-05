/// The JUnit writer shared by the host and device flavors. The host output is
/// unchanged by moving it here.
library;

import 'results.dart';

/// The error location as the user sees it. A tester stack names the
/// execroot-relative URI; the package part is cut so that a failure reads
/// `test/foo_test.dart:12`, and other files read as their execroot path.
String displayPath(String text, String packageRoot) => text
    .replaceAll('org-dartlang-root:///$packageRoot/', '')
    .replaceAll('org-dartlang-root:///', '');

/// The JUnit report of [cases], for suite [suite].
String junitReport(String suite, List<CaseResult> cases, String packageRoot) {
  var failures = 0;
  var errors = 0;
  var skipped = 0;
  final body = StringBuffer();
  for (final result in cases) {
    final name = _xml(result.name);
    final classname = _xml(suite);
    final message = _xml(displayPath(result.message, packageRoot));
    final firstLine = _xml(
      displayPath(result.message, packageRoot).split('\n').first,
    );
    final tags = _tagProperties(result.tags);
    switch (result.outcome) {
      case Outcome.pass:
        body.write(_testcase(classname, name, tags, ''));
      case Outcome.skip:
        skipped++;
        final reason = message.isEmpty ? '' : ' message="$message"';
        body.write(_testcase(classname, name, tags, '<skipped$reason/>'));
      case Outcome.fail:
        failures++;
        body.write(
          _testcase(
            classname,
            name,
            tags,
            '<failure message="$firstLine">$message</failure>',
          ),
        );
      case Outcome.error:
        errors++;
        body.write(
          _testcase(
            classname,
            name,
            tags,
            '<error message="$firstLine">$message</error>',
          ),
        );
    }
  }
  return '<?xml version="1.0" encoding="UTF-8"?>'
      '<testsuite name="${_xml(suite)}" tests="${cases.length}" '
      'failures="$failures" errors="$errors" skipped="$skipped">'
      '$body</testsuite>';
}

/// Tags are JUnit properties, so a report can be filtered by tag.
String _tagProperties(List<String> tags) {
  if (tags.isEmpty) return '';
  final properties = tags
      .map((tag) => '<property name="tag" value="${_xml(tag)}"/>')
      .join();
  return '<properties>$properties</properties>';
}

String _testcase(String classname, String name, String tags, String inner) =>
    '<testcase classname="$classname" name="$name">$tags$inner</testcase>';

String _xml(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');
