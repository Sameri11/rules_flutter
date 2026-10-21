"""Parse Bazel's --execution_log_json_file.

The file is a stream of pretty-printed SpawnExec JSON objects, not one object per line.
Field names were checked against Bazel 9.2.0 output: `mnemonic`, `runner`, `cacheHit`,
and `metrics.totalTime` (a proto Duration string such as "1.250s"). Durations may also be
numbers or {seconds, nanos} objects. A missing file counts as zero spawns.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

KERNEL_MNEMONICS = ("DartTestKernel", "DartLibTier")
KERNEL_STEPS = ("cold", "wide", "test")
SANDBOX_RUNNERS = frozenset({"darwin-sandbox", "linux-sandbox", "processwrapper-sandbox", "sandboxed"})
_DURATION_RE = re.compile(r"^(-?\d+(?:\.\d+)?)s$")


def is_worker_runner(runner):
    return runner == "worker" or runner.startswith("worker")


def _seconds(value):
    if value is None or isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        match = _DURATION_RE.match(value.strip())
        return float(match.group(1)) if match else None
    if isinstance(value, dict):
        try:
            return float(value.get("seconds", 0)) + float(value.get("nanos", 0)) / 1e9
        except (TypeError, ValueError):
            return None
    return None


def _new_stats():
    return {
        "count": 0,
        "cache_hit": 0,
        "executed": 0,
        "wall_s": 0.0,
        "executed_runners": {},
        "cache_hit_runners": {},
    }


def _spawns(text, stats):
    """Yield each SpawnExec object in the stream; a bad object ends the stream."""
    decoder = json.JSONDecoder()
    index = 0
    while True:
        while index < len(text) and text[index].isspace():
            index += 1
        if index >= len(text):
            return
        try:
            spawn, index = decoder.raw_decode(text, index)
        except ValueError:
            stats["unparsed_lines"] += 1
            return
        yield spawn


def parse_execlog(path):
    stats = {name: _new_stats() for name in KERNEL_MNEMONICS}
    stats["unparsed_lines"] = 0
    log_file = Path(path)
    if not log_file.is_file():
        return stats
    for spawn in _spawns(log_file.read_text(errors="replace"), stats):
        if not isinstance(spawn, dict):
            continue
        mnemonic = spawn.get("mnemonic")
        if mnemonic not in KERNEL_MNEMONICS:
            continue
        entry = stats[mnemonic]
        runner = str(spawn.get("runner") or "")
        hit = spawn.get("cacheHit") is True or "cache hit" in runner
        entry["count"] += 1
        entry["cache_hit" if hit else "executed"] += 1
        bucket = entry["cache_hit_runners" if hit else "executed_runners"]
        bucket[runner] = bucket.get(runner, 0) + 1
        metrics = spawn.get("metrics") or {}
        seconds = _seconds(metrics.get("totalTime"))
        if seconds is None:
            seconds = _seconds(metrics.get("executionWallTime"))
        if seconds is None:
            seconds = _seconds(spawn.get("wallTime"))
        if seconds is not None:
            entry["wall_s"] += seconds
    return stats


def summarize(stats):
    out = {}
    for name in KERNEL_MNEMONICS:
        entry = stats[name]
        out[name] = {
            "count": entry["count"],
            "executed": entry["executed"],
            "cache_hit": entry["cache_hit"],
            "wall_s": round(entry["wall_s"], 3),
            "runners": sorted(entry["executed_runners"]),
            "cache_hit_runners": sorted(entry["cache_hit_runners"]),
        }
    out["unparsed_lines"] = stats["unparsed_lines"]
    return out


def check(stats, mode, step):
    """Return reasons this step's spawns are unusable. Empty list means valid.

    Cold and wide steps start from a salted cache with no kernel entries, so any
    kernel cache hit there means reuse across modes or repeats. The test step
    reuses every unchanged kernel from the cold step, so only the edited test
    kernel may execute.
    """
    reasons = []
    kernel = stats["DartTestKernel"]
    lib = stats["DartLibTier"]
    if step in ("cold", "wide"):
        if kernel["cache_hit"]:
            reasons.append("DartTestKernel cache hit x%d" % kernel["cache_hit"])
        if lib["cache_hit"]:
            reasons.append("DartLibTier cache hit x%d" % lib["cache_hit"])
    if step == "test" and kernel["executed"] != 1:
        reasons.append("test step executed %d DartTestKernel spawns, expected 1" % kernel["executed"])
    if step in KERNEL_STEPS and kernel["count"] == 0:
        reasons.append("no DartTestKernel spawn in %s step" % step)
    for runner in sorted(kernel["executed_runners"]):
        if mode == "batch":
            ok = runner in SANDBOX_RUNNERS
            expected = "a sandbox runner"
        else:
            ok = is_worker_runner(runner)
            expected = "a worker"
        if not ok:
            reasons.append("DartTestKernel ran on runner %r; mode %s expects %s" % (runner, mode, expected))
    for runner in sorted(lib["executed_runners"]):
        if runner not in SANDBOX_RUNNERS:
            reasons.append("DartLibTier ran on runner %r; expected a sandbox runner" % runner)
    return reasons
