#!/usr/bin/env python3
"""Report Bazel cache-hit and execution counts per category from build logs.

Every category Bazel prints in its `N processes: ...` summary is tracked, so a
run's cache hits and its remaining real work are both visible. Without the
execution categories a summary line like

    2926 processes: 2202 remote cache hit, 668 internal, 58 darwin-sandbox.

shows 2202 hits out of 2926 and looks like a 75% hit rate, when in fact 668 of
those are internal actions that never consult a cache and only 58 actions
actually re-executed.

Bazel's own category counts do not always sum to its process total (the line
above sums to 2928), so no attempt is made to reconcile them.

Test results come from Bazel's `Executed N out of T tests` summary. A test that
Bazel served from the cache prints `(cached)` on its result line, and is counted
separately from the executed ones.
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import astuple, dataclass
from pathlib import Path
from typing import Sequence


SUMMARY_RE = re.compile(
    r"^\s*(?:INFO:\s*)?(?P<processes>\d+)\s+process(?:es)?\s*:\s*(?P<body>.*)$"
)

# Bazel names the sandbox strategy after the platform: darwin-sandbox on macOS,
# linux-sandbox and processwrapper-sandbox elsewhere. Bucket them together so
# the same table is comparable across runners.
SANDBOX_RE = re.compile(r"(\d+)\s+[a-z0-9]+-sandbox\b")

# Persistent workers report as `worker`, multiplexed ones as `multiplex-worker`,
# and a single build can use both.
WORKER_RE = re.compile(r"(\d+)\s+(?:multiplex-)?worker\b")

# Bazel's test summary, e.g. `Executed 0 out of 7 tests: 7 tests pass.`
TEST_SUMMARY_RE = re.compile(
    r"^\s*(?:INFO:\s*)?Executed (?P<executed>\d+) out of (?P<total>\d+) tests?\b"
)

# A test served from the cache prints `(cached)` in place of its timing.
CACHED_TEST_RE = re.compile(r"^//\S+\s+\(cached\)")

# Label, width. One spec keeps the header, the rows, and the TOTAL line from
# drifting apart as categories are added.
COLUMNS: tuple[tuple[str, int], ...] = (
    ("Processes", 9),
    ("Action-cache", 12),
    ("Remote-cache", 12),
    ("Internal", 8),
    ("Sandbox", 7),
    ("Worker", 6),
    ("Local", 5),
)
NAME_WIDTH = 35


@dataclass
class CacheStats:
    # Field order matches COLUMNS; `cells` and `__add__` both rely on it.
    processes: int = 0
    action_cache_hits: int = 0
    remote_cache_hits: int = 0
    internal_actions: int = 0
    sandbox_actions: int = 0
    worker_actions: int = 0
    local_actions: int = 0

    @classmethod
    def from_summary_line(cls, line: str) -> CacheStats | None:
        """Parse one Bazel summary, accepting INFO prefixes and omitted fields."""
        match = SUMMARY_RE.match(line)
        if match is None:
            return None
        body = match.group("body")

        def hits(label: str) -> int:
            found = re.search(rf"(\d+)\s+{label}\s+hits?\b", body)
            return int(found.group(1)) if found else 0

        def total(pattern: re.Pattern[str]) -> int:
            return sum(int(n) for n in pattern.findall(body))

        def count(label: str) -> int:
            found = re.search(rf"(\d+)\s+{label}\b", body)
            return int(found.group(1)) if found else 0

        return cls(
            processes=int(match.group("processes")),
            action_cache_hits=hits("action cache"),
            remote_cache_hits=hits("remote cache"),
            internal_actions=count("internal"),
            sandbox_actions=total(SANDBOX_RE),
            worker_actions=total(WORKER_RE),
            local_actions=count("local"),
        )

    def __add__(self, other: CacheStats) -> CacheStats:
        # Positional so a new field cannot be forgotten here.
        return CacheStats(*(a + b for a, b in zip(astuple(self), astuple(other))))

    def cells(self) -> tuple[str, ...]:
        return tuple(str(value) for value in astuple(self))

    @property
    def executed(self) -> int:
        """Actions that did real work, so neither cached nor Bazel-internal."""
        return self.sandbox_actions + self.worker_actions + self.local_actions


def parse_log(text: str) -> CacheStats | None:
    """Aggregate every Bazel summary found in one captured invocation log."""
    total: CacheStats | None = None
    for line in text.splitlines():
        stats = CacheStats.from_summary_line(line)
        if stats is not None:
            total = stats if total is None else total + stats
    return total


def extract_stats_from_log(log_path: Path) -> CacheStats | None:
    try:
        return parse_log(log_path.read_text())
    except FileNotFoundError:
        return None


def has_remote_cache_hits(stats: CacheStats | None) -> bool:
    return stats is not None and stats.remote_cache_hits > 0


@dataclass(frozen=True)
class TestStats:
    executed: int
    cached: int
    total: int


def parse_test_log(text: str) -> TestStats | None:
    """Sum Bazel's test summaries in one log, and count its `(cached)` test lines."""
    lines = text.splitlines()
    executed = total = 0
    found = False
    for line in lines:
        match = TEST_SUMMARY_RE.match(line)
        if match is not None:
            found = True
            executed += int(match.group("executed"))
            total += int(match.group("total"))
    if not found:
        return None
    cached = sum(1 for line in lines if CACHED_TEST_RE.match(line))
    return TestStats(executed=executed, cached=cached, total=total)


def extract_test_stats_from_log(log_path: Path) -> TestStats | None:
    try:
        return parse_test_log(log_path.read_text())
    except FileNotFoundError:
        return None


def format_row(name: str, cells: Sequence[str]) -> str:
    padded = " ".join(f"{cell:>{width}}" for cell, (_, width) in zip(cells, COLUMNS))
    return f"{name:<{NAME_WIDTH}} {padded}"


def format_stats_table(
    invocations: list[tuple[str, CacheStats | None]], totals: CacheStats | None
) -> str:
    header = format_row("Invocation", [label for label, _ in COLUMNS])
    lines = [header, "-" * len(header)]
    missing = ("-",) * len(COLUMNS)
    for name, stats in invocations:
        lines.append(format_row(name, missing if stats is None else stats.cells()))
    if totals is not None:
        lines.append("-" * len(header))
        lines.append(format_row("TOTAL", totals.cells()))
        lines.append(
            "Cached {} of {} non-internal actions; {} re-executed.".format(
                totals.action_cache_hits + totals.remote_cache_hits,
                totals.action_cache_hits + totals.remote_cache_hits + totals.executed,
                totals.executed,
            )
        )
    return "\n".join(lines)


def format_test_lines(results: list[tuple[str, TestStats | None]]) -> list[str]:
    return [
        f"{name}: tests: {stats.executed} executed, {stats.cached} cached (of {stats.total})"
        for name, stats in results
        if stats is not None
    ]


def selftest() -> int:
    """Exercise real summary lines, every category, and aggregation."""
    # Verbatim from the warm demo_app CI run.
    warm = parse_log(
        "INFO: 2926 processes: 2202 remote cache hit, 668 internal, 58 darwin-sandbox.\n"
    )
    assert warm == CacheStats(
        processes=2926, remote_cache_hits=2202, internal_actions=668, sandbox_actions=58
    ), warm
    assert warm.executed == 58

    # Verbatim from the preceding, colder run: every category at once.
    cold = parse_log(
        "INFO: 2926 processes: 1595 remote cache hit, 668 internal, "
        "571 darwin-sandbox, 3 local, 91 worker.\n"
    )
    assert cold == CacheStats(
        processes=2926,
        remote_cache_hits=1595,
        internal_actions=668,
        sandbox_actions=571,
        worker_actions=91,
        local_actions=3,
    ), cold
    assert cold.executed == 665

    # Verbatim from the ubuntu lint job: a different sandbox strategy name.
    lint = parse_log("INFO: 9 processes: 6 internal, 4 processwrapper-sandbox.\n")
    assert lint == CacheStats(processes=9, internal_actions=6, sandbox_actions=4), lint

    # Both worker flavours in one line are summed, not overwritten.
    workers = parse_log("INFO: 5 processes: 2 worker, 3 multiplex-worker.\n")
    assert workers == CacheStats(processes=5, worker_actions=5), workers

    # Local action cache and remote cache are distinct categories.
    both = parse_log("INFO: 3 processes: 2 action cache hits, 1 remote cache hit.\n")
    assert both == CacheStats(processes=3, action_cache_hits=2, remote_cache_hits=1)

    # Aggregation across invocations sums every field.
    assert warm + cold == CacheStats(
        processes=5852,
        remote_cache_hits=3797,
        internal_actions=1336,
        sandbox_actions=629,
        worker_actions=91,
        local_actions=3,
    )

    assert parse_log("unrelated output\n") is None
    assert has_remote_cache_hits(warm)
    assert not has_remote_cache_hits(lint)
    assert has_remote_cache_hits(None) is False

    # Header, rows, and TOTAL stay aligned because they share COLUMNS.
    table = format_stats_table([("warm.log", warm), ("absent.log", None)], warm)
    widths = {len(line) for line in table.splitlines()[:5]}
    assert len(widths) == 1, table
    assert "Sandbox" in table and "Internal" in table and "Worker" in table
    assert "Cached 2202 of 2260 non-internal actions; 58 re-executed." in table

    tests = parse_test_log(
        "//:a_test                                                       (cached) PASSED in 1.1s\n"
        "//:b_test                                                       (cached) PASSED in 0.2s\n"
        "Executed 0 out of 2 tests: 2 tests pass.\n"
    )
    assert tests == TestStats(executed=0, cached=2, total=2), tests

    cold_tests = parse_test_log(
        "//:a_test                                                       PASSED in 2.0s\n"
        "//:b_test                                                       PASSED in 0.5s\n"
        "//:c_test                                                       PASSED in 0.7s\n"
        "Executed 3 out of 3 tests: 3 tests pass.\n"
    )
    assert cold_tests == TestStats(executed=3, cached=0, total=3), cold_tests

    # A partly cached run: one test re-executed, two served from the cache.
    mixed = parse_test_log(
        "//:a_test                                                       (cached) PASSED in 1.1s\n"
        "//:b_test                                                       (cached) PASSED in 0.2s\n"
        "//:c_test                                                       PASSED in 0.7s\n"
        "Executed 1 out of 3 tests: 3 tests pass.\n"
    )
    assert mixed == TestStats(executed=1, cached=2, total=3), mixed
    assert parse_test_log("INFO: 5 processes: 5 internal.\n") is None
    assert format_test_lines([("warm.log", tests), ("absent.log", None), ("mixed.log", mixed)]) == [
        "warm.log: tests: 0 executed, 2 cached (of 2)",
        "mixed.log: tests: 1 executed, 2 cached (of 3)",
    ]

    print("OK: cache summary and test summary parsing, table layout passed")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("logs", nargs="*", help="Captured Bazel logs")
    parser.add_argument("--selftest", action="store_true", help="Run parser selftests")
    parser.add_argument(
        "--require-hits",
        action="store_true",
        help="Fail when the supplied logs contain no remote-cache hits",
    )
    args = parser.parse_args()
    if args.selftest:
        return selftest()
    if not args.logs:
        parser.error("at least one log is required unless --selftest is used")

    invocations: list[tuple[str, CacheStats | None]] = []
    tests: list[tuple[str, TestStats | None]] = []
    totals: CacheStats | None = None
    for log_name in args.logs:
        log = Path(log_name)
        stats = extract_stats_from_log(log)
        invocations.append((log.name, stats))
        tests.append((log.name, extract_test_stats_from_log(log)))
        if stats is not None:
            totals = stats if totals is None else totals + stats
    print(format_stats_table(invocations, totals))
    for line in format_test_lines(tests):
        print(line)
    if args.require_hits and not has_remote_cache_hits(totals):
        print("ERROR: reading build produced zero remote-cache hits", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
