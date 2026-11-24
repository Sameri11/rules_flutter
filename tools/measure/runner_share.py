#!/usr/bin/env python3
"""Measure cold, test-edit and wide-lib Bazel test runs for a fetched app copy."""

import argparse
import atexit
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time
import sys


def run(command, cwd, log_path):
    started = time.monotonic()
    with log_path.open("wb") as log:
        result = subprocess.run(command, cwd=cwd, stdout=log, stderr=subprocess.STDOUT, check=False)
    return {"exit_code": result.returncode, "wall_s": round(time.monotonic() - started, 3)}


def kernel_artifacts(app, base, suite, out):
    expression = 'mnemonic("DartTestKernel", deps(tests(%s)))' % suite
    result = subprocess.run(
        ["bazel", "--output_base=" + str(base), "aquery", "--output=jsonproto", expression],
        cwd=app, text=True, capture_output=True, check=False,
    )
    if result.returncode:
        raise SystemExit("kernel aquery failed:\n" + result.stderr)
    from bazel_io import parse_actions
    actions = parse_actions(json.loads(result.stdout))
    files = sorted({name for action in actions if action["mnemonic"] == "DartTestKernel"
                    for name in action["outputs"] if name.endswith(".dill")})
    sizes = [{"path": name, "bytes": (app / name).stat().st_size}
             for name in files if (app / name).is_file()]
    (out / "kernel-artifacts.json").write_text(json.dumps(
        {"count": len(sizes), "bytes": sum(item["bytes"] for item in sizes), "files": sizes},
        indent=2, sort_keys=True) + "\n")


def state():
    uptime = subprocess.run(["uptime"], text=True, capture_output=True, check=False).stdout.strip()
    swap = {}
    vmstat = Path("/proc/vmstat")
    if vmstat.exists():
        for line in vmstat.read_text().splitlines():
            key, _, value = line.partition(" ")
            if key in {"pswpin", "pswpout"}:
                swap[key] = int(value) * 4096 / 1024 / 1024
    return {"uptime": uptime, "swap_pages_mb": swap}


def swap_in_delta(before, after):
    start = before["swap_pages_mb"].get("pswpin")
    end = after["swap_pages_mb"].get("pswpin")
    return None if start is None or end is None else max(0.0, end - start)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", choices=["serverbox", "oinkoin"], required=True)
    parser.add_argument("--app-dir", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--mode", choices=["per-file", "directory", "count4"], default="per-file")
    args = parser.parse_args()
    app = args.app_dir.resolve()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    base = Path(os.environ.get("RUNNER_TEMP", "/tmp")) / ("bnt20-" + args.app + "-" + args.mode)
    atexit.register(
        lambda: subprocess.run(["bazel", "--output_base=" + str(base), "shutdown"], cwd=app,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    )
    suite = {
        "directory": "//:flutter_tests_directory",
        "count4": "//:flutter_tests_g4",
        "per-file": "//:flutter_tests",
    }[args.mode]
    query = subprocess.run(
        ["bazel", "--output_base=" + str(base), "query", "--output=label", "tests(" + suite + ")"],
        cwd=app, text=True, capture_output=True, check=False,
    )
    if query.returncode:
        raise SystemExit("target query failed:\n" + query.stderr)
    floor_target = "//:runner_floor_test"
    all_targets = sorted({line.strip() for line in query.stdout.splitlines() if line.strip()})
    suite_targets = [target for target in all_targets if target != floor_target]
    expected_suite = {"serverbox": 239, "oinkoin": 98}[args.app]
    if args.mode == "per-file" and (len(suite_targets) != expected_suite or floor_target not in all_targets):
        raise SystemExit("unexpected suite/floor target count: suite=%d floor=%s" %
                         (len(suite_targets), floor_target in all_targets))
    targets = suite_targets + ([floor_target] if args.mode == "per-file" else [])
    (out / "targets.txt").write_text("\n".join(targets) + "\n")
    (out / "target-counts.json").write_text(json.dumps(
        {"mode": args.mode, "suite": len(suite_targets), "suite_targets": suite_targets}, indent=2) + "\n")
    source = app / ("lib/data/model/app/tab.dart" if args.app == "serverbox" else "lib/services/service-config.dart")
    original = source.read_bytes()
    (out / "host.json").write_text(json.dumps({"app": args.app, "revision": subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=Path(__file__).resolve().parents[2], text=True).strip(),
        "host": subprocess.check_output(["uname", "-a"], text=True).strip()}, indent=2) + "\n")
    records = []
    try:
        if args.mode == "per-file":
            floor_profile = out / "runner-floor.profile.gz"
            floor_execlog = out / "runner-floor.compact"
            floor_log = out / "runner-floor.log"
            floor_command = ["bazel", "--output_base=" + str(base), "test", "--keep_going",
                             "--nocache_test_results", "--disk_cache=", "--remote_cache=",
                             "--profile=" + str(floor_profile),
                             "--execution_log_compact_file=" + str(floor_execlog), floor_target]
            floor_state = state()
            floor_result = run(floor_command, app, floor_log)
            floor_after = state()
            floor_xml = app / "bazel-testlogs/runner_floor_test/test.xml"
            if floor_xml.exists():
                shutil.copy2(floor_xml, out / "runner-floor.xml")
            floor_swap = swap_in_delta(floor_state, floor_after)
            records.append({"run": "runner-floor", "before": floor_state, "after": floor_after,
                            "swap_in_mb": floor_swap, "valid": None if floor_swap is None else floor_swap < 256,
                            **floor_result, "profile": floor_profile.name, "execution_log": floor_execlog.name,
                            "test_xml": "runner-floor.xml"})
            if floor_result["exit_code"] not in (0, 3):
                raise SystemExit("runner floor failed; see %s" % floor_log)
        for mode_name, targets_for_run, output_base in (
                ("cold", suite_targets, base.with_name(base.name + "-cold")),
                ("test-edit", suite_targets, base)):
            if mode_name == "test-edit":
                test_file = next(iter(sorted((app / "test").rglob("*_test.dart"))), None)
                if test_file is None:
                    continue
                test_original = test_file.read_bytes()
                test_file.write_bytes(test_original + b"\n// runner-share test-edit\n")
            command = ["bazel", "--output_base=" + str(output_base), "test", "--keep_going",
                       "--nocache_test_results", "--disk_cache=", "--remote_cache=",
                       "--profile=" + str(out / (mode_name + ".profile.gz"))] + targets_for_run
            result = run(command, app, out / (mode_name + ".log"))
            if mode_name == "test-edit":
                test_file.write_bytes(test_original)
            else:
                subprocess.run(["bazel", "--output_base=" + str(output_base), "shutdown"], cwd=app,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
            records.append({"run": mode_name, **result, "profile": mode_name + ".profile.gz"})
            if result["exit_code"] not in (0, 3):
                raise SystemExit("%s failed; see %s" % (mode_name, out / (mode_name + ".log")))
        for repeat in range(1, args.repeats + 1):
            before = state()
            command = ["bazel", "--output_base=" + str(base), "test", "--keep_going",
                       "--nocache_test_results", "--disk_cache=", "--remote_cache="] + targets
            result = run(command, app, out / ("warm-r%d.log" % repeat))
            after = state()
            records.append({"run": "warm-r%d" % repeat, "before": before, "after": after,
                            "swap_in_mb": swap_in_delta(before, after), **result})
            if result["exit_code"] not in (0, 3):
                raise SystemExit("warm-r%d failed; see %s" % (repeat, out / ("warm-r%d.log" % repeat)))
            source.write_bytes(original + ("\n// runner-share marker %s\n" % repeat).encode())
            before = state()
            profile = out / ("wide-r%d.profile.gz" % repeat)
            execlog = out / ("wide-r%d.compact" % repeat)
            command = ["bazel", "--output_base=" + str(base), "test", "--keep_going",
                       "--nocache_test_results", "--disk_cache=", "--remote_cache=", "--profile=" + str(profile),
                       "--execution_log_compact_file=" + str(execlog)] + targets
            result = run(command, app, out / ("wide-r%d.log" % repeat))
            after = state()
            swap = swap_in_delta(before, after)
            records.append({"run": "wide-r%d" % repeat, "before": before, "after": after,
                            "swap_in_mb": swap, "valid": None if swap is None else swap < 256,
                            **result, "profile": profile.name, "execution_log": execlog.name})
            source.write_bytes(original)
            if result["exit_code"] not in (0, 3):
                raise SystemExit("wide-r%d failed; see %s" % (repeat, out / ("wide-r%d.log" % repeat)))
    finally:
        source.write_bytes(original)
        subprocess.run(["bazel", "--output_base=" + str(base), "shutdown"], cwd=app,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    testlogs = app / "bazel-testlogs"
    if testlogs.exists():
        shutil.copytree(testlogs, out / "testlogs", dirs_exist_ok=True)
    kernel_artifacts(app, base, suite, out)
    (out / "records.json").write_text(json.dumps(records, indent=2, sort_keys=True) + "\n")
    (out / "commands.txt").write_text("bazel test --keep_going --nocache_test_results --disk_cache= --remote_cache= <suite targets>\n")
    subprocess.run([sys.executable, str(Path(__file__).with_name("analyze_runner_share.py")),
                    "--out", str(out), "--app", args.app], check=True)


if __name__ == "__main__":
    main()
