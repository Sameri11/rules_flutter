#!/usr/bin/env python3
"""Measure warm and wide-lib Bazel test runs for one fetched app copy."""

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
    args = parser.parse_args()
    app = args.app_dir.resolve()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    base = Path(os.environ.get("RUNNER_TEMP", "/tmp")) / ("bnt18-" + args.app)
    atexit.register(
        lambda: subprocess.run(["bazel", "--output_base=" + str(base), "shutdown"], cwd=app,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    )
    query = subprocess.run(
        ["bazel", "--output_base=" + str(base), "query", "--output=label", "tests(//:flutter_tests)"],
        cwd=app, text=True, capture_output=True, check=False,
    )
    if query.returncode:
        raise SystemExit("target query failed:\n" + query.stderr)
    floor_target = "//:runner_floor_test"
    synthetic_targets = ["//:test_measure_defines_test"] if args.app == "serverbox" else []
    all_targets = sorted({line.strip() for line in query.stdout.splitlines() if line.strip()}
                         | {floor_target} | set(synthetic_targets))
    suite_targets = [target for target in all_targets if target not in [floor_target] + synthetic_targets]
    expected_suite = {"serverbox": 239, "oinkoin": 98}[args.app]
    if len(suite_targets) != expected_suite or floor_target not in all_targets:
        raise SystemExit("unexpected suite/floor target count: suite=%d floor=%s" %
                         (len(suite_targets), floor_target in all_targets))
    targets = suite_targets + [floor_target]
    (out / "targets.txt").write_text("\n".join(targets) + "\n")
    (out / "target-counts.json").write_text(json.dumps(
        {"suite": len(suite_targets), "synthetic_defines": len(synthetic_targets), "runner_floor": 1,
         "suite_targets": suite_targets, "synthetic_targets": synthetic_targets}, indent=2) + "\n")
    source = app / ("lib/data/model/app/tab.dart" if args.app == "serverbox" else "lib/services/service-config.dart")
    original = source.read_bytes()
    (out / "host.json").write_text(json.dumps({"app": args.app, "revision": subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=Path(__file__).resolve().parents[2], text=True).strip(),
        "host": subprocess.check_output(["uname", "-a"], text=True).strip()}, indent=2) + "\n")
    records = []
    try:
        floor_profile = out / "runner-floor.profile.gz"
        floor_execlog = out / "runner-floor.compact"
        floor_log = out / "runner-floor.log"
        floor_command = ["bazel", "--output_base=" + str(base), "test", "--keep_going",
                         "--nocache_test_results", "--disk_cache=", "--remote_cache=",
                         "--profile=" + str(floor_profile),
                         "--execution_log_compact_file=" + str(floor_execlog), "//:runner_floor_test"]
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
        if synthetic_targets:
            synthetic_profile = out / "synthetic-defines.profile.gz"
            synthetic_execlog = out / "synthetic-defines.compact"
            synthetic_log = out / "synthetic-defines.log"
            synthetic_before = state()
            synthetic_command = ["bazel", "--output_base=" + str(base), "test", "--keep_going",
                                "--nocache_test_results", "--disk_cache=", "--remote_cache=",
                                "--profile=" + str(synthetic_profile),
                                "--execution_log_compact_file=" + str(synthetic_execlog)] + synthetic_targets
            synthetic_result = run(synthetic_command, app, synthetic_log)
            synthetic_after = state()
            synthetic_xml = app / "bazel-testlogs/test_measure_defines_test/test.xml"
            if synthetic_xml.exists():
                shutil.copy2(synthetic_xml, out / "synthetic-defines.xml")
            records.append({"run": "synthetic-defines", "before": synthetic_before, "after": synthetic_after,
                            "swap_in_mb": swap_in_delta(synthetic_before, synthetic_after),
                            **synthetic_result, "profile": synthetic_profile.name,
                            "execution_log": synthetic_execlog.name})
            if synthetic_result["exit_code"] not in (0, 3):
                raise SystemExit("synthetic defines target failed; see %s" % synthetic_log)
        for repeat in range(1, args.repeats + 1):
            before = state()
            command = ["bazel", "--output_base=" + str(base), "test", "--keep_going",
                       "--disk_cache=", "--remote_cache="] + targets
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
                       "--disk_cache=", "--remote_cache=", "--profile=" + str(profile),
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
    (out / "records.json").write_text(json.dumps(records, indent=2, sort_keys=True) + "\n")
    (out / "commands.txt").write_text("bazel test --keep_going --disk_cache= --remote_cache= <all suite targets>\\n")
    subprocess.run([sys.executable, str(Path(__file__).with_name("analyze_runner_share.py")),
                    "--out", str(out), "--app", args.app], check=True)


if __name__ == "__main__":
    main()
