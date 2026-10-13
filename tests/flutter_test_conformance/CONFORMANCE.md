# Host test driver conformance (C1–C15)

The host driver (`flutter/private/test/driver/`) runs each fixture through `flutter_tester` and must report the same per-case outcomes as `flutter test --reporter json` on the same SDK.

- `cN_<name>.expected.json`: per run, the environment, the CLI exit code, and each case's outcome (`pass`, `fail`, `skip`, `error`) in run order. `load` is the suite-load case.
- `check.py` runs the launcher per run and checks the exit code, the JUnit cases, that no `org-dartlang-root:` URI appears, and that sharded runs touch `TEST_SHARD_STATUS_FILE`.

## Re-baselining

```
bazel test //tests/flutter_test_conformance/...               # driver against the oracles
python3 tests/flutter_test_conformance/rebaseline.py --check  # oracles against flutter test
python3 tests/flutter_test_conformance/rebaseline.py          # rewrite after an intended change
```

`rebaseline.py` refuses to run unless the Flutter SDK matches `MODULE.bazel` (Flutter 3.47.3).
## Cases
| Id | Fixture | Exit | Outcomes (CLI and driver agree) |
|---|---|---|---|
| C1 | `c1_lifecycle` | 0 | hook and test order: pass |
| C2 | `c2_skip` | 0 | skipped tests and groups: skip |
| C3 | `c3_timeout` | 1 | explicit timeout: error; default: pass |
| C4 | `c4_names` | 0 | full nested name: pass |
| C5 | `c5_expect_async` | 1 | called: pass; not called: error |
| C6 | `c6_async_errors` | 1 | error before completion: error; after: pass |
| C7 | `c7_teardown` | 1 | `addTearDown` and tests in hook groups: pass; failing `setUpAll`/`tearDownAll`: error `(setUpAll)` / `(tearDownAll)`; failing `tearDown` body: error |
| C8 | `c8_config` | 0 | `testExecutable` wrapper: pass |
| C9 | `c9_platform_tags` | 0 | tagged test: pass; `testOn: browser` test filtered out |
| C10 | `c10_reporting` | 1 | load error |
| C11 | `c11_widgets` | 1 | variants and `runAsync`: pass; pending timer, build exception: error |
| C12 | `c12_retry` | 0 | flaky test: pass on second attempt |
| C13 | `c13_filter` | 0 | default, `--name`, and shard selections match the CLI (test_core's slice formula) |
| C14 | `c14_async_main` | 0 | test declared after an `await` in `main`: pass |
| C15 | `c15_late_declare` | 1 | hand-written: `declared in time` pass; late `test()`: load error |

## Known divergences
- **C15.** The CLI attributes a `test()` called after the tests have begun to the running test, or with none running reports "No tests were found" and exits 0. The driver reports a `load` error and exits 1, so `c15_late_declare.expected.json` is hand-written and `rebaseline.py` does not write it.
- **`suiteChannel`.** test_api 0.7.12 has no public route through `openChannelCallback`, so `spawn-hybrid-uri` cases fail at once. Hybrid-channel suites are unsupported.
- **Library annotations.** Library-level annotations such as `@Skip` are unsupported. C2's library-level `@Skip` line was removed.
- **`--packages` omitted.** The pub hub's `package_config.json` uses execroot-relative `rootUri`s, which do not resolve in runfiles. The kernel already holds every imported library.
