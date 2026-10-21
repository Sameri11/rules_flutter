#!/usr/bin/env python3
"""Cold `bazel test` of every test target of one wired app copy, one status per target.

Targets are `tests(//...)` minus labels in an android/ package (the same set measure.py uses). The
run is cold: fresh output base, no disk cache, no remote cache. Each target's status
comes from the build event stream; a target with no test result is BUILD_FAILED when
Bazel reports its completion as unsuccessful and NO_RESULT otherwise.

Writes into --out: status-<app>.tsv (label TAB status), run-<app>.json, bep-<app>.json,
test-<app>.log. Exit 0 whatever the tests did; exit 2 only for harness errors.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
from pathlib import Path

import bazel_io


def fail(message):
    print("parity: %s" % message, file=sys.stderr)
    sys.exit(2)


def test_labels(app_dir, scratch):
    ob = scratch / "ob" / "query"
    labels = bazel_io.query_test_targets(ob, None, app_dir)
    bazel_io.shutdown(ob, None, app_dir)
    labels = [t for t in labels if not bazel_io.is_android_label(t)]
    if not labels:
        fail("no test targets in %s" % app_dir)
    return labels


def parse_bep(path, labels):
    results = {}
    completed_ok = {}
    if not Path(path).is_file():
        return results, completed_ok
    for line in Path(path).read_text(errors="replace").splitlines():
        if not line.strip():
            continue
        event = json.loads(line)
        event_id = event.get("id", {})
        if "testResult" in event_id and "testResult" in event:
            label = event_id["testResult"]["label"]
            results[label] = event["testResult"]["status"]
        elif "targetCompleted" in event_id:
            label = event_id["targetCompleted"]["label"]
            completed_ok[label] = bool(event.get("completed", {}).get("success", False))
    status = {}
    for label in labels:
        if label in results:
            status[label] = results[label]
        elif label in completed_ok and not completed_ok[label]:
            status[label] = "BUILD_FAILED"
        else:
            status[label] = "NO_RESULT"
    return status, completed_ok


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", required=True)
    parser.add_argument("--rules-root", required=True)
    parser.add_argument("--scratch", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--timeout-min", type=float, required=True)
    args = parser.parse_args(argv)

    app_dir = Path(args.rules_root).resolve() / "_apps" / args.app
    if not (app_dir / "MODULE.bazel").is_file():
        fail("%s is not wired" % app_dir)
    scratch = Path(args.scratch).resolve()
    out = Path(args.out).resolve()
    out.mkdir(parents=True, exist_ok=True)

    labels = test_labels(app_dir, scratch)
    (out / ("targets-%s.txt" % args.app)).write_text("\n".join(labels) + "\n")

    ob = scratch / "ob" / "test"
    bep_path = out / ("bep-%s.json" % args.app)
    log_path = out / ("test-%s.log" % args.app)
    cmd = bazel_io.bazel_cmd(
        ob,
        None,
        "test",
        "--keep_going",
        "--disk_cache=",
        "--test_output=errors",
        "--nocache_test_results",
        "--build_event_json_file=%s" % bep_path,
        *labels,
    )
    started = time.time()
    timed_out = False
    exit_code = None
    with log_path.open("w") as log:
        try:
            exit_code = subprocess.run(cmd, cwd=app_dir, stdout=log, stderr=subprocess.STDOUT, timeout=args.timeout_min * 60).returncode
        except subprocess.TimeoutExpired:
            timed_out = True
    wall = time.time() - started
    if timed_out:
        subprocess.run(["bazel", "--output_base=%s" % ob, "shutdown"], cwd=app_dir, check=False)

    status, _ = parse_bep(bep_path, labels)
    with (out / ("status-%s.tsv" % args.app)).open("w") as fh:
        for label in labels:
            fh.write("%s\t%s\n" % (label, status[label]))
    counts = {}
    for value in status.values():
        counts[value] = counts.get(value, 0) + 1
    run = {
        "app": args.app,
        "targets": len(labels),
        "exit_code": exit_code,
        "timed_out": timed_out,
        "wall_s": round(wall, 1),
        "counts": counts,
    }
    (out / ("run-%s.json" % args.app)).write_text(json.dumps(run, indent=2, sort_keys=True) + "\n")
    print(json.dumps(run, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
