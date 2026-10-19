#!/usr/bin/env python3
"""Summarize measurement records as markdown.

Usage: summarize.py --out FILE PATH [PATH ...]
PATH is a records.jsonl file, or a directory searched for records.jsonl and hardening.json.

Only valid, non-superseded records are used. A strategy wins a step only when the gap
between its median and the next median exceeds the larger of their spreads (max - min
over the repeats). Q5 is adopted only when bytes per lib edit (the wide step) fall by at
least 50% against worker and median test-kernel action time (the test step) grows by at
most 20%.
"""

from __future__ import annotations

import argparse
import json
import statistics
import sys
from collections import Counter
from pathlib import Path

BAZEL_MODES = ("batch", "worker", "q5")
OS_TITLE = {"linux": "Linux (ubuntu-latest)", "macos": "macOS (macos-15)"}
BYTES_DROP_MIN = 0.5
TIME_GROWTH_MAX = 0.2


def _files(paths, name):
    found = []
    for raw in paths:
        path = Path(raw)
        if path.is_dir():
            found.extend(sorted(path.rglob(name)))
        elif path.is_file() and path.name == name:
            found.append(path)
    return found


def load_records(paths):
    records = []
    for file in _files(paths, "records.jsonl"):
        for line in file.read_text().splitlines():
            if line.strip():
                records.append(json.loads(line))
    return records


def load_hardening(paths):
    results = []
    for file in _files(paths, "hardening.json"):
        results.append((str(file), json.loads(file.read_text())))
    return results


def metric(rec, name):
    if name == "wall":
        return rec.get("wall_s")
    if name == "execution":
        return (rec.get("profile") or {}).get("execution_s")
    if name == "kernel":
        kernel = (rec.get("spawns") or {}).get("DartTestKernel") or {}
        return kernel.get("wall_s") if kernel.get("count") else None
    if name == "bytes":
        sizes = rec.get("bytes") or {}
        if sizes.get("up") is None and sizes.get("down") is None:
            return None
        return (sizes.get("up") or 0) + (sizes.get("down") or 0)
    raise KeyError(name)


def index_records(records):
    index = {}
    for rec in records:
        if rec.get("superseded") or not rec.get("valid"):
            continue
        index.setdefault((rec["os"], rec["app"], rec["mode"], rec["step"]), []).append(rec)
    return index


def values(index, os_name, app, mode, step, name):
    found = []
    for rec in index.get((os_name, app, mode, step), []):
        value = metric(rec, name)
        if value is not None:
            found.append(value)
    return found


def summary_stat(samples):
    if not samples:
        return None
    return {
        "median": statistics.median(samples),
        "spread": max(samples) - min(samples),
        "n": len(samples),
    }


def verdict(stats):
    """Name the winner of a step, or say why there is none."""
    ranked = sorted(((mode, s) for mode, s in stats.items() if s), key=lambda item: item[1]["median"])
    if len(ranked) < 2:
        return "verdict: insufficient data"
    (best, best_s), (second, second_s) = ranked[0], ranked[1]
    margin = second_s["median"] - best_s["median"]
    bar = max(best_s["spread"], second_s["spread"])
    if margin > bar:
        return "verdict: %s leads %s by %.2f (bar %.2f)" % (best, second, margin, bar)
    return "verdict: no winner; margin %.2f does not exceed spread bar %.2f" % (margin, bar)


def fmt(value, digits=2):
    return "n/a" if value is None else ("%." + str(digits) + "f") % value


def q5_line(index, os_name, app):
    worker_bytes = values(index, os_name, app, "worker", "wide", "bytes")
    q5_bytes = values(index, os_name, app, "q5", "wide", "bytes")
    worker_time = values(index, os_name, app, "worker", "test", "kernel")
    q5_time = values(index, os_name, app, "q5", "test", "kernel")
    if not (worker_bytes and q5_bytes and worker_time and q5_time):
        return "Q5 verdict: insufficient data"
    base_bytes = statistics.median(worker_bytes)
    base_time = statistics.median(worker_time)
    drop = 1 - statistics.median(q5_bytes) / base_bytes if base_bytes > 0 else None
    growth = statistics.median(q5_time) / base_time - 1 if base_time > 0 else None
    adopt = drop is not None and growth is not None and drop >= BYTES_DROP_MIN and growth <= TIME_GROWTH_MAX
    return (
        "Q5 verdict: %s (bytes per lib edit %s vs worker, drop %s; test-kernel action time %s)"
        % (
            "ADOPT" if adopt else "do not adopt",
            fmt(statistics.median(q5_bytes), 0),
            "n/a" if drop is None else "%.0f%%" % (drop * 100),
            "n/a" if growth is None else "%+.0f%%" % (growth * 100),
        )
    )


def identity_lines(records):
    groups = {}
    for rec in records:
        digest = rec.get("test_kernel_digest")
        if rec.get("superseded") or not rec.get("valid") or not digest:
            continue
        if rec["mode"] not in BAZEL_MODES:
            continue
        key = (rec["os"], rec["app"], rec["rep"], rec["step"])
        groups.setdefault(key, {})[rec["mode"]] = digest
    lines = []
    same = 0
    for key in sorted(groups):
        seen = groups[key]
        if len(set(seen.values())) == 1:
            same += 1
        else:
            lines.append("- MISMATCH %s rep %s step %s: %s" % (key[0] + "/" + key[1], key[2], key[3], sorted(seen)))
    return ["Digest identity: %d of %d groups identical across modes" % (same, len(groups))] + lines


def invalid_lines(records):
    counts = Counter()
    reruns = Counter()
    reasons = Counter()
    for rec in records:
        if rec.get("superseded"):
            continue
        key = (rec["os"], rec["app"], rec["mode"])
        counts[key] += 1
        if rec.get("rerun"):
            reruns[key] += 1
        for reason in rec.get("invalid_reasons") or []:
            reasons[(key, reason)] += 1
    lines = ["| OS | app | mode | records | invalid | reruns |", "| --- | --- | --- | ---: | ---: | ---: |"]
    for key in sorted(counts):
        invalid = sum(1 for r in records if not r.get("superseded") and not r.get("valid") and (r["os"], r["app"], r["mode"]) == key)
        lines.append("| %s | %s | %s | %d | %d | %d |" % (key[0], key[1], key[2], counts[key], invalid, reruns[key]))
    for (key, reason), count in sorted(reasons.items()):
        lines.append("- %s/%s/%s: %s (x%d)" % (key[0], key[1], key[2], reason, count))
    return lines


def host_lines(records):
    seen = {}
    for rec in records:
        seen.setdefault((rec["os"], rec["app"]), rec.get("host") or {})
    lines = []
    for (os_name, app), host in sorted(seen.items()):
        lines.append(
            "- %s / %s: image %s, CPU %s, %s vCPU, %s MB RAM"
            % (
                os_name,
                app,
                host.get("image_version") or "n/a",
                host.get("cpu_model") or "n/a",
                host.get("nproc"),
                host.get("ram_mb"),
            )
        )
    return lines


def bazel_section(index, os_name, app):
    lines = []
    for step in ("cold", "wide", "test"):
        lines.append("")
        lines.append("#### step `%s`" % step)
        lines.append("")
        lines.append("| mode | n | wall median (s) | wall spread | execution median (s) | kernel action median (s) | kernel spread | bytes median |")
        lines.append("| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
        per_metric = {name: {} for name in ("wall", "execution", "kernel")}
        for mode in BAZEL_MODES:
            wall = summary_stat(values(index, os_name, app, mode, step, "wall"))
            execution = summary_stat(values(index, os_name, app, mode, step, "execution"))
            kernel = summary_stat(values(index, os_name, app, mode, step, "kernel"))
            size = summary_stat(values(index, os_name, app, mode, step, "bytes"))
            per_metric["wall"][mode] = wall
            per_metric["execution"][mode] = execution
            per_metric["kernel"][mode] = kernel
            if not wall:
                lines.append("| %s | 0 | n/a | n/a | n/a | n/a | n/a | n/a |" % mode)
                continue
            lines.append(
                "| %s | %d | %s | %s | %s | %s | %s | %s |"
                % (
                    mode,
                    wall["n"],
                    fmt(wall["median"]),
                    fmt(wall["spread"]),
                    fmt(execution["median"]) if execution else "n/a",
                    fmt(kernel["median"]) if kernel else "n/a",
                    fmt(kernel["spread"]) if kernel else "n/a",
                    fmt(size["median"], 0) if size else "n/a",
                )
            )
        lines.append("")
        lines.append("- wall: %s" % verdict(per_metric["wall"]))
        lines.append("- execution: %s" % verdict(per_metric["execution"]))
    lines.append("")
    lines.append("- %s" % q5_line(index, os_name, app))
    return lines


def flutter_section(index, os_name, app, records):
    lines = ["| step | n | wall median (s) | passed | failed | skipped |", "| --- | ---: | ---: | ---: | ---: | ---: |"]
    for step in ("pubget", "flutter"):
        recs = [r for r in records if r["os"] == os_name and r["app"] == app and r["mode"] == "flutter" and r["step"] == step and not r.get("superseded") and r.get("valid")]
        walls = [r["wall_s"] for r in recs if r.get("wall_s") is not None]
        counts = [r.get("flutter") or {} for r in recs]
        if not recs:
            lines.append("| %s | 0 | n/a | n/a | n/a | n/a |" % step)
            continue
        lines.append(
            "| %s | %d | %s | %s | %s | %s |"
            % (
                step,
                len(recs),
                fmt(statistics.median(walls)) if walls else "n/a",
                sum(c.get("passed", 0) for c in counts) // max(1, len(counts)),
                sum(c.get("failed", 0) for c in counts) // max(1, len(counts)),
                sum(c.get("skipped", 0) for c in counts) // max(1, len(counts)),
            )
        )
    return lines


def hardening_lines(results):
    if not results:
        return ["No hardening record found."]
    lines = []
    for path, doc in results:
        checks = doc.get("checks") or {}
        lines.append(
            "- %s: %s (target %s; %s)"
            % (
                Path(path).parent.name,
                "PASSED" if doc.get("passed") else "FAILED",
                doc.get("target"),
                ", ".join("%s=%s" % (k, v) for k, v in sorted(checks.items())),
            )
        )
    return lines


def build_markdown(records, hardening):
    index = index_records(records)
    total = sum(1 for r in records if not r.get("superseded"))
    valid = sum(1 for r in records if not r.get("superseded") and r.get("valid"))
    out = [
        "# Test-kernel measurement summary",
        "",
        "Records: %d valid of %d non-superseded." % (valid, total),
        "",
        "## Hosts",
        "",
    ]
    out.extend(host_lines(records))
    out.extend(["", "## Validity", ""])
    out.extend(invalid_lines(records))
    out.extend(["", "## Digest identity", ""])
    out.extend(identity_lines(records))
    keys = sorted({(r["os"], r["app"]) for r in records})
    for os_name, app in keys:
        out.extend(["", "## %s: %s" % (OS_TITLE.get(os_name, os_name), app), ""])
        out.append("### Bazel modes")
        out.extend(bazel_section(index, os_name, app))
        out.extend(["", "### Flutter"])
        out.extend(flutter_section(index, os_name, app, records))
    out.extend(["", "## Hardening (linux)", ""])
    out.extend(hardening_lines(hardening))
    out.append("")
    return "\n".join(out)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", required=True)
    parser.add_argument("paths", nargs="+")
    args = parser.parse_args(argv)
    records = load_records(args.paths)
    if not records:
        print("summarize: no records found", file=sys.stderr)
        return 2
    text = build_markdown(records, load_hardening(args.paths))
    Path(args.out).write_text(text)
    print("summarize: wrote %s (%d records)" % (args.out, len(records)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
