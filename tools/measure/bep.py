"""Parsers for Bazel's build event stream and --profile trace.

BEP (--build_event_json_file): one JSON BuildEvent per line. The harness reads
`buildMetrics` (actionSummary, networkMetrics, timingMetrics) and `finished`.
Proto3 JSON writes int64 values as strings, so counts go through int().
UNVERIFIED: key spellings beyond the proto field names listed above. A missing
field is reported as null; it does not invalidate a run.

Profile (--profile): a Chrome trace {"otherData": {...}, "traceEvents": [...]},
gzip-compressed. Checked on a local Bazel 9.2.0 profile: phase markers are
instant events ("ph": "i") such as "Evaluate target patterns", and duration
events ("ph": "X", "dur" in microseconds) include "evaluateTargetPatterns",
"runAnalysisAndExecutionPhase" and "skyframeExecutor.evaluateBuildDriverKeys".
Derived fields are [INFERENCE]: analysis_s = runAnalysisAndExecutionPhase minus
skyframeExecutor.evaluateBuildDriverKeys. fetch_s is null unless a fetch-named
duration event exists.
"""

from __future__ import annotations

import gzip
import json
from pathlib import Path

LOADING_EVENT = "evaluateTargetPatterns"
ANALYSIS_EXECUTION_EVENT = "runAnalysisAndExecutionPhase"
EXECUTION_EVENT = "skyframeExecutor.evaluateBuildDriverKeys"


def _as_int(value):
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def read_maybe_gzip(path):
    raw = Path(path).read_bytes()
    if raw[:2] == b"\x1f\x8b":
        raw = gzip.decompress(raw)
    return raw.decode("utf-8", errors="replace")


def parse_bep(path):
    result = {
        "found": False,
        "actions_created": None,
        "actions_executed": None,
        "remote_cache_hits": None,
        "bytes_sent": None,
        "bytes_recv": None,
        "wall_ms": None,
        "finished_exit_code": None,
        "failing_tests": [],
    }
    if not Path(path).is_file():
        return result
    failing = set()
    for line in Path(path).read_text(errors="replace").splitlines():
        if not line.strip():
            continue
        try:
            event = json.loads(line)
        except ValueError:
            continue
        if not isinstance(event, dict):
            continue
        test_summary = (event.get("id") or {}).get("testSummary")
        if isinstance(test_summary, dict) and isinstance(event.get("testSummary"), dict):
            status = event["testSummary"].get("overallStatus", "UNKNOWN")
            if status != "PASSED":
                failing.add(test_summary.get("label", "?"))
        metrics = event.get("buildMetrics")
        if isinstance(metrics, dict):
            result["found"] = True
            summary = metrics.get("actionSummary") or {}
            result["actions_created"] = _as_int(summary.get("actionsCreated"))
            result["actions_executed"] = _as_int(summary.get("actionsExecuted"))
            result["remote_cache_hits"] = _as_int(summary.get("remoteCacheHits"))
            network = (metrics.get("networkMetrics") or {}).get("systemNetworkStats") or {}
            result["bytes_sent"] = _as_int(network.get("bytesSent"))
            result["bytes_recv"] = _as_int(network.get("bytesRecv"))
            timing = metrics.get("timingMetrics") or {}
            result["wall_ms"] = _as_int(timing.get("wallTimeInMs"))
        finished = event.get("finished")
        if isinstance(finished, dict) and "exitCode" in finished:
            code = finished["exitCode"] or {}
            result["finished_exit_code"] = _as_int(code.get("code", 0))
    result["failing_tests"] = sorted(failing)
    return result


def _duration_totals(events):
    totals = {}
    fetch_s = 0.0
    fetch_count = 0
    for event in events:
        if not isinstance(event, dict) or "dur" not in event:
            continue
        try:
            seconds = float(event["dur"]) / 1e6
        except (TypeError, ValueError):
            continue
        name = str(event.get("name", ""))
        totals[name] = totals.get(name, 0.0) + seconds
        if "fetch" in name.lower() or "fetch" in str(event.get("cat", "")).lower():
            fetch_s += seconds
            fetch_count += 1
    return totals, fetch_s, fetch_count


def parse_profile(path):
    result = {
        "parsed": False,
        "events": 0,
        "fetch_s": None,
        "analysis_s": None,
        "execution_s": None,
        "loading_s": None,
        "analysis_execution_s": None,
    }
    if not Path(path).is_file():
        return result
    try:
        doc = json.loads(read_maybe_gzip(path))
    except (OSError, ValueError, EOFError):
        return result
    events = doc.get("traceEvents") if isinstance(doc, dict) else doc
    if not isinstance(events, list):
        return result
    result["parsed"] = True
    result["events"] = len(events)
    totals, fetch_s, fetch_count = _duration_totals(events)
    if fetch_count:
        result["fetch_s"] = round(fetch_s, 6)
    loading = totals.get(LOADING_EVENT)
    phase = totals.get(ANALYSIS_EXECUTION_EVENT)
    execution = totals.get(EXECUTION_EVENT)
    if loading is not None:
        result["loading_s"] = round(loading, 6)
    if phase is not None:
        result["analysis_execution_s"] = round(phase, 6)
    if execution is not None:
        result["execution_s"] = round(execution, 6)
    if phase is not None and execution is not None:
        result["analysis_s"] = round(max(0.0, phase - execution), 6)
    return result
