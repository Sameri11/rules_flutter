#!/usr/bin/env python3
"""Report Bazel action, remote-cache, and local execution counts from logs."""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path


SUMMARY_RE = re.compile(
    r"^\s*(?:INFO:\s*)?(?P<processes>\d+)\s+process(?:es)?\s*:\s*(?P<body>.*)$"
)


@dataclass
class CacheStats:
    processes: int = 0
    action_cache_hits: int = 0
    remote_cache_hits: int = 0
    local_actions: int = 0

    @classmethod
    def from_summary_line(cls, line: str) -> CacheStats | None:
        """Parse one Bazel summary, accepting INFO prefixes and omitted fields."""
        match = SUMMARY_RE.match(line)
        if match is None:
            return None
        body = match.group("body")

        def count(label: str) -> int:
            found = re.search(rf"(\d+)\s+{label}\s+hits?\b", body)
            return int(found.group(1)) if found else 0

        local = re.search(r"(\d+)\s+local\b", body)
        return cls(
            processes=int(match.group("processes")),
            action_cache_hits=count("action cache"),
            remote_cache_hits=count("remote cache"),
            local_actions=int(local.group(1)) if local else 0,
        )

    def __add__(self, other: CacheStats) -> CacheStats:
        return CacheStats(
            self.processes + other.processes,
            self.action_cache_hits + other.action_cache_hits,
            self.remote_cache_hits + other.remote_cache_hits,
            self.local_actions + other.local_actions,
        )


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


def format_stats_table(
    invocations: list[tuple[str, CacheStats | None]], totals: CacheStats | None
) -> str:
    header = (
        f"{'Invocation':<35} {'Processes':>9} {'Action-cache':>13} "
        f"{'Remote-cache':>12} {'Local':>5}"
    )
    lines = [header, "-" * len(header)]
    for name, stats in invocations:
        if stats is None:
            values = ("-", "-", "-", "-")
        else:
            values = (
                str(stats.processes),
                str(stats.action_cache_hits),
                str(stats.remote_cache_hits),
                str(stats.local_actions),
            )
        lines.append(
            f"{name:<35} {values[0]:>9} {values[1]:>13} "
            f"{values[2]:>12} {values[3]:>5}"
        )
    if totals is not None:
        lines.extend(
            [
                "-" * len(header),
                f"{'TOTAL':<35} {totals.processes:>9} "
                f"{totals.action_cache_hits:>13} {totals.remote_cache_hits:>12} "
                f"{totals.local_actions:>5}",
            ]
        )
    return "\n".join(lines)


def selftest() -> int:
    """Exercise real prefixes, omitted categories, aggregation, and hit gating."""
    parsed = parse_log(
        "INFO: 3 processes: 2 action cache hits, 1 remote cache hit, 0 local.\n"
        "INFO: 45 processes: 2 internal, 43 remote cache hit.\n"
    )
    assert parsed == CacheStats(processes=48, action_cache_hits=2, remote_cache_hits=44)

    omitted = parse_log("INFO: 2 processes: 2 local.\n")
    assert omitted == CacheStats(processes=2, local_actions=2)
    assert parse_log("unrelated output\n") is None
    cold = CacheStats(processes=2, local_actions=2)

    assert has_remote_cache_hits(parsed)
    assert not has_remote_cache_hits(cold)
    assert has_remote_cache_hits(None) is False
    print("OK: cache summary parsing and hit gating selftests passed")
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
    totals: CacheStats | None = None
    for log_name in args.logs:
        stats = extract_stats_from_log(Path(log_name))
        invocations.append((Path(log_name).name, stats))
        if stats is not None:
            totals = stats if totals is None else totals + stats
    print(format_stats_table(invocations, totals))
    if args.require_hits and not has_remote_cache_hits(totals):
        print("ERROR: reading build produced zero remote-cache hits", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
