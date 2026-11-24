#!/usr/bin/env python3
"""Summarize Bazel profile traces from runner-share measurement logs."""

import argparse
import gzip
import json
from pathlib import Path
import re
import statistics
import math
import xml.etree.ElementTree as ET


import heapq
def profile(path):
    with gzip.open(path, "rt", encoding="utf-8") as handle:
        doc = json.load(handle)
    return doc.get("traceEvents", doc.get("trace_events", []))


def target_from_name(name):
    match = re.search(r"//[A-Za-z0-9_.+/-]*(?::[A-Za-z0-9_.+/-]+)?", name)
    return match.group(0) if match else ""


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
        name = str(event.get("name", ""))
        label = args.get("label") or args.get("target") or args.get("targetLabel") or target_from_name(name)
        rows.append({"mnemonic": str(mnemonic), "start_us": start, "end_us": start + duration,
                     "wall_s": duration / 1_000_000, "label": str(label), "name": name})
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


def failed_targets(log_path):
    return set(re.findall(r"^FAIL: (//[^\s]+)", log_path.read_text(errors="replace"), re.MULTILINE))


def summarize_run(profile_path, log_path, floor_xml=None, suite_only=True):
    events = profile(profile_path)
    rows = actions(events)
    suite_rows = ([row for row in rows if row["label"] != "//:runner_floor_test"
                   and "runner_floor_test" not in row["name"]] if suite_only else rows)
    totals = {}
    for row in suite_rows:
        totals[row["mnemonic"]] = totals.get(row["mnemonic"], 0.0) + row["wall_s"]
    runners = [row for row in suite_rows if row["mnemonic"] == "TestRunner"]
    failures = failed_targets(log_path)
    for row in runners:
        row["status"] = "failed" if row["label"] in failures else "passed"
    def concurrency_of(selected):
        edges = sorted((t, change) for row in selected
                       for t, change in ((row["start_us"], 1), (row["end_us"], -1)))
        active = maximum = 0
        for _, change in edges:
            active += change
            maximum = max(maximum, active)
        return maximum
    maximum = concurrency_of(runners)
    passing_concurrency = concurrency_of([row for row in runners if row["status"] == "passed"])
    critical_components = [event for event in events if event.get("cat") == "critical path component"]
    critical_total = sum(float(event.get("dur", 0)) for event in critical_components) / 1_000_000
    critical_runner = sum(float(event.get("dur", 0)) for event in critical_components
                          if str(event.get("name", "")).startswith("action 'Testing //:")
                          and "runner_floor_test" not in str(event.get("name", ""))) / 1_000_000
    runner_sum = totals.get("TestRunner", 0.0)
    action_sum = sum(totals.values())
    critical = critical_path(log_path)
    xml_s = test_xml_seconds(floor_xml) if floor_xml else None
    return {"wall_s": bazel_wall(log_path), "wall_critical_path_s": critical,
            "mnemonic_wall_s": totals,
            "test_runner_share_of_sum": runner_sum / action_sum if action_sum else None,
            "test_runner_critical_path_s": critical_runner,
            "test_runner_share_of_critical_path": critical_runner / critical_total if critical_total else None,
            "runner_count": len(runners), "runners": runners,
            "runner_concurrency": maximum, "runner_concurrency_passing": passing_concurrency,
            "floor_test_xml_s": xml_s,
            "fixed_process_s": None}
def percentile(values, fraction):
    return values[max(0, math.ceil(fraction * len(values)) - 1)] if values else None


def timing_stats(values, fixed_s):
    values = sorted(values)
    body = sorted(max(0.0, value - fixed_s) for value in values)
    return {"count": len(values),
            "median_s": statistics.median(values) if values else None,
            "p90_s": percentile(values, 0.90),
            "body_median_s": statistics.median(body) if body else None,
            "body_p90_s": percentile(body, 0.90)}


def projection(count, grouping, fixed_s, concurrency, median_wall):
    size = count if grouping == "all" else grouping
    groups = math.ceil(count / size) if count else 0
    saved = fixed_s * (count - groups) / max(1, concurrency)
    return {"targets": count, "groups": groups, "saved_wall_s": saved,
            "saved_wall_fraction": saved / median_wall if median_wall else None}

def list_makespan(durations, slots):
    available = [0.0] * slots
    heapq.heapify(available)
    for duration in durations:
        earliest = heapq.heappop(available)
        heapq.heappush(available, earliest + duration)
    return max(available, default=0.0)


def wave_projection(runs, grouping, fixed_s, passing_only):
    per_run = []
    for run in runs.values():
        runners = sorted((runner for runner in run["runners"]
                          if not passing_only or runner["status"] == "passed"),
                         key=lambda runner: runner["label"])
        body_times = [max(0.0, runner["wall_s"] - fixed_s) for runner in runners]
        file_times = [fixed_s + body for body in body_times]
        group_size = len(body_times) if grouping == "all" else grouping
        grouped_times = [fixed_s + sum(body_times[index:index + group_size])
                         for index in range(0, len(body_times), group_size)]
        baseline = list_makespan(file_times, 4)
        grouped = list_makespan(grouped_times, 4)
        per_run.append({"per_file_makespan_s": baseline, "grouped_makespan_s": grouped,
                        "saved_wall_s": baseline - grouped, "targets": len(body_times),
                        "groups": len(grouped_times)})
    return {"targets": per_run[0]["targets"] if per_run else 0,
            "groups": per_run[0]["groups"] if per_run else 0,
            "per_file_makespan_median_s": statistics.median(
                row["per_file_makespan_s"] for row in per_run) if per_run else None,
            "grouped_makespan_median_s": statistics.median(
                row["grouped_makespan_s"] for row in per_run) if per_run else None,
            "saved_wall_median_s": statistics.median(
                row["saved_wall_s"] for row in per_run) if per_run else None,
            "per_run": per_run,
            "formula": "group body = sum(max(0, runner_wall - fixed_process)); add fixed_process once; list-schedule groups on 4 slots"}


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
    floor_result = summarize_run(floor, root / "runner-floor.log", root / "runner-floor.xml",
                                 suite_only=False) if floor.exists() else None
    synthetic_profile = root / "synthetic-defines.profile.gz"
    synthetic_result = summarize_run(synthetic_profile, root / "synthetic-defines.log",
                                     root / "synthetic-defines.xml", suite_only=False) if synthetic_profile.exists() else None
    fixed = None
    if floor_result and floor_result["runners"]:
        floor_runner = floor_result["runners"][0]["wall_s"]
        floor_xml_s = floor_result["floor_test_xml_s"] or 0.0
        fixed = max(0.0, floor_runner - floor_xml_s)
        floor_result["fixed_floor_runner_s"] = floor_runner
        floor_result["fixed_process_s"] = fixed
    median_wall = statistics.median(row["wall_s"] for row in runs.values()
                                    if row["wall_s"] is not None) if runs else None
    suite_count = round(statistics.median(row["runner_count"] for row in runs.values())) if runs else 0
    passing_counts = [sum(runner["status"] == "passed" for runner in row["runners"])
                      for row in runs.values()]
    passing_count = round(statistics.median(passing_counts)) if passing_counts else 0
    concurrency = max((row["runner_concurrency"] for row in runs.values()), default=1)
    passing_concurrency = max((row["runner_concurrency_passing"] for row in runs.values()), default=1)
    pass_times = [runner["wall_s"] for row in runs.values() for runner in row["runners"]
                  if runner["status"] == "passed"]
    fail_times = [runner["wall_s"] for row in runs.values() for runner in row["runners"]
                  if runner["status"] == "failed"]
    all_times = pass_times + fail_times
    projections = {"all_targets": {}, "passing_targets_only": {}}
    wave_projections = {"all_targets": {}, "passing_targets_only": {}}
    if fixed is not None:
        for key, count, observed in (("all_targets", suite_count, concurrency),
                                     ("passing_targets_only", passing_count, passing_concurrency)):
            for group in (4, 16, "all"):
                projections[key][str(group)] = projection(count, group, fixed, observed, median_wall)
                projections[key][str(group)]["formula"] = (
                    "fixed_process_s * (runner_count - ceil(runner_count/g)) / observed_concurrency"
                )
        for key, passing_only in (("all_targets", False), ("passing_targets_only", True)):
            for group in (4, 16, "all"):
                wave_projections[key][str(group)] = wave_projection(
                    runs, group, fixed, passing_only)
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
              "test_runner_critical_path_median_s": statistics.median(
                  row["test_runner_critical_path_s"] for row in runs.values()) if runs else None,
              "mnemonic_wall_median_s": {
                  name: statistics.median(row["mnemonic_wall_s"].get(name, 0.0) for row in runs.values())
                  for name in mnemonics},
              "runner_count": suite_count, "passing_runner_count": passing_count,
              "failing_runner_count": suite_count - passing_count,
              "observed_concurrency": concurrency,
              "passing_observed_concurrency": passing_concurrency,
              "runner_spawn_passing": timing_stats(pass_times, fixed or 0.0),
              "runner_spawn_failing": timing_stats(fail_times, fixed or 0.0),
              "runner_spawn_all": timing_stats(all_times, fixed or 0.0),
              "fixed_process_s": fixed, "grouping_projection": projections,
              "wave_aware_grouping_projection": wave_projections}
    (root / "summary.json").write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
