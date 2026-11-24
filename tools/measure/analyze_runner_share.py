#!/usr/bin/env python3
"""Summarize Bazel profile traces from runner-share measurement logs."""

import argparse
import gzip
import json
from pathlib import Path
import re
import statistics
import xml.etree.ElementTree as ET


def profile(path):
    with gzip.open(path, "rt", encoding="utf-8") as handle:
        doc = json.load(handle)
    return doc.get("traceEvents", doc.get("trace_events", []))


def actions(events):
    rows = []
    for event in events:
        args = event.get("args") or {}
        mnemonic = args.get("mnemonic") or args.get("mnemonicName")
        category = str(event.get("cat", "")).lower()
        if not mnemonic or not ("action" in category or mnemonic == "TestRunner"):
            continue
        if event.get("ph") not in ("X", None):
            continue
        start = float(event.get("ts", 0))
        duration = float(event.get("dur", args.get("duration", 0)))
        if duration <= 0:
            continue
        label = args.get("label") or args.get("target") or args.get("targetLabel") or ""
        rows.append({"mnemonic": str(mnemonic), "start_us": start, "end_us": start + duration,
                     "wall_s": duration / 1_000_000, "label": str(label)})
    return rows


def bazel_wall(log_path):
    text = log_path.read_text(errors="replace")
    values = re.findall(r"Elapsed time:\s*([0-9.]+)s", text)
    return float(values[-1]) if values else None


def critical_path(log_path):
    text = log_path.read_text(errors="replace")
    values = re.findall(r"Critical Path:\s*([0-9.]+)s", text)
    return float(values[-1]) if values else None


def test_xml_seconds(path):
    if not path.exists():
        return None
    root = ET.parse(path).getroot()
    value = root.attrib.get("time")
    if value is None and root.tag == "testsuites":
        value = root.attrib.get("time")
    return float(value) if value else 0.0


def summarize_run(profile_path, log_path, floor_xml=None):
    rows = actions(profile(profile_path))
    totals = {}
    for row in rows:
        totals[row["mnemonic"]] = totals.get(row["mnemonic"], 0.0) + row["wall_s"]
    runners = [row for row in rows if row["mnemonic"] == "TestRunner"]
    intervals = sorted((row["start_us"], row["end_us"]) for row in runners)
    active = maximum = 0
    edges = sorted((t, change) for start, end in intervals for t, change in ((start, 1), (end, -1)))
    for _, change in edges:
        active += change
        maximum = max(maximum, active)
    runner_times = sorted(row["wall_s"] for row in runners)
    xml_s = test_xml_seconds(floor_xml) if floor_xml else None
    runner_sum = totals.get("TestRunner", 0.0)
    action_sum = sum(totals.values())
    critical = critical_path(log_path)
    return {"wall_s": bazel_wall(log_path), "wall_critical_path_s": critical,
            "mnemonic_wall_s": totals, "test_runner_share_of_sum": runner_sum / action_sum if action_sum else None,
            "test_runner_share_of_critical_path": runner_sum / critical if critical else None,
            "runner_count": len(runners), "runner_times_s": runner_times,
            "runner_concurrency": maximum, "fixed_floor_runner_s": runner_times[0] if runner_times else None,
            "floor_test_xml_s": xml_s,
            "fixed_process_s": (runner_times[0] - xml_s) if runner_times and xml_s is not None else None}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--app", required=True)
    args = parser.parse_args()
    root = args.out
    runs = {}
    for path in sorted(root.glob("wide-r*.profile.gz")):
        label = path.name.removesuffix(".profile.gz")
        runs[label] = summarize_run(path, root / (label + ".log"))
    floor = root / "runner-floor.profile.gz"
    floor_result = summarize_run(floor, root / "runner-floor.log", root / "runner-floor.xml") if floor.exists() else None
    synthetic_profile = root / "synthetic-defines.profile.gz"
    synthetic_result = summarize_run(synthetic_profile, root / "synthetic-defines.log",
                                     root / "synthetic-defines.xml") if synthetic_profile.exists() else None
    runner_times = sorted(value for row in runs.values() for value in row["runner_times_s"])
    runner_count = round(statistics.median(row["runner_count"] for row in runs.values())) if runs else 0
    concurrency = max((row["runner_concurrency"] for row in runs.values()), default=1)
    fixed = floor_result["fixed_process_s"] if floor_result else None
    projections = {}
    median_wall = statistics.median(row["wall_s"] for row in runs.values()
                                    if row["wall_s"] is not None) if runs else None
    if fixed is not None and runner_count:
        for grouping in sorted({4, 16, runner_count}):
            groups = (runner_count + grouping - 1) // grouping
            saved = fixed * (runner_count - groups) / max(1, concurrency)
            projections[str(grouping)] = {
                "groups": groups, "saved_wall_s": saved,
                "saved_wall_fraction": saved / median_wall if median_wall else None,
                "formula": "fixed_process_s * (runner_count - ceil(runner_count/g)) / observed_concurrency",
            }
    mnemonics = sorted({name for row in runs.values() for name in row["mnemonic_wall_s"]})
    result = {"app": args.app, "runs": runs, "runner_floor": floor_result,
              "synthetic_defines": synthetic_result,
              "wall_median_s": median_wall,
              "critical_path_median_s": statistics.median(row["wall_critical_path_s"] for row in runs.values()
                                                          if row["wall_critical_path_s"] is not None) if runs else None,
              "test_runner_share_of_sum_median": statistics.median(
                  row["test_runner_share_of_sum"] for row in runs.values()
                  if row["test_runner_share_of_sum"] is not None) if runs else None,
              "test_runner_share_of_critical_path_median": statistics.median(
                  row["test_runner_share_of_critical_path"] for row in runs.values()
                  if row["test_runner_share_of_critical_path"] is not None) if runs else None,
              "mnemonic_wall_median_s": {
                  name: statistics.median(row["mnemonic_wall_s"].get(name, 0.0) for row in runs.values())
                  for name in mnemonics},
              "runner_count": runner_count, "observed_concurrency": concurrency,
              "runner_spawn_median_s": statistics.median(runner_times) if runner_times else None,
              "runner_spawn_p90_s": runner_times[max(0, int(0.9 * len(runner_times) + 0.999999) - 1)] if runner_times else None,
              "fixed_process_s": fixed, "grouping_projection": projections}
    (root / "summary.json").write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
