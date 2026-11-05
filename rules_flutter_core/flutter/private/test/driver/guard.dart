/// Runs a suite's declaration in a zone that reports its errors to the listener.
library;

import 'dart:async';

import 'results.dart';

/// Runs [body] in a zone. Errors while main is declaring go to the listener's
/// own zone. Later errors are recorded in [errors] as load failures, because
/// the listener sends them after `success`, which the core ignores.
Future<void> guarded(
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
