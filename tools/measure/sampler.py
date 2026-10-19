"""Memory, swap and load sampler for a measured process tree.

Every INTERVAL_S seconds the sampler sums the resident set of:
- the client process and its descendants,
- the Bazel server, found through the output base path in its command line or
  through server/server.pid.txt when present, and its descendants,
- every process whose command contains one of DART_PATTERNS.
Swap comes from `sysctl -n vm.swapusage` on macOS and /proc/meminfo on Linux.
load1 comes from os.getloadavg().
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
import threading
from dataclasses import dataclass

INTERVAL_S = 1.0
DART_PATTERNS = ("driver.dill", "frontend_server", "dartaotruntime")
_SWAP_RE = re.compile(r"used\s*=\s*([0-9.]+)([MG])")


@dataclass
class ProcInfo:
    ppid: int
    rss_kb: int
    cmd: str


def _run_text(cmd):
    return subprocess.run(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        universal_newlines=True,
        check=True,
    ).stdout


def _table_ps():
    table = {}
    for line in _run_text(["ps", "-axo", "pid=,ppid=,rss=,command="]).splitlines():
        parts = line.strip().split(None, 3)
        if len(parts) < 3:
            continue
        cmd = parts[3] if len(parts) == 4 else ""
        table[int(parts[0])] = ProcInfo(int(parts[1]), int(parts[2]), cmd)
    return table


def _table_proc():
    table = {}
    for name in os.listdir("/proc"):
        if not name.isdigit():
            continue
        pid = int(name)
        try:
            with open("/proc/%d/stat" % pid) as handle:
                stat_line = handle.read()
            ppid = int(stat_line.rsplit(")", 1)[1].split()[1])
            rss = 0
            with open("/proc/%d/status" % pid) as handle:
                for line in handle:
                    if line.startswith("VmRSS:"):
                        rss = int(line.split()[1])
                        break
            with open("/proc/%d/cmdline" % pid, "rb") as handle:
                cmd = handle.read().replace(b"\0", b" ").decode("utf-8", "replace").strip()
        except (OSError, ValueError, IndexError):
            continue
        table[pid] = ProcInfo(ppid, rss, cmd)
    return table


def read_process_table():
    return _table_ps() if sys.platform == "darwin" else _table_proc()


def swap_used_mb():
    if sys.platform == "darwin":
        match = _SWAP_RE.search(_run_text(["sysctl", "-n", "vm.swapusage"]))
        if not match:
            raise ValueError("unrecognised vm.swapusage output")
        value = float(match.group(1))
        return value * 1024.0 if match.group(2) == "G" else value
    values = {}
    with open("/proc/meminfo") as handle:
        for line in handle:
            key, _, rest = line.partition(":")
            if key in ("SwapTotal", "SwapFree"):
                values[key] = int(rest.split()[0])
    return (values["SwapTotal"] - values["SwapFree"]) / 1024.0


def _descendants(table, roots):
    children = {}
    for pid, info in table.items():
        children.setdefault(info.ppid, []).append(pid)
    seen = set()
    stack = list(roots)
    while stack:
        pid = stack.pop()
        if pid in seen:
            continue
        seen.add(pid)
        stack.extend(children.get(pid, ()))
    return seen


def _server_pid(output_base):
    try:
        with open(os.path.join(output_base, "server", "server.pid.txt")) as handle:
            return int(handle.read().strip())
    except (OSError, ValueError):
        return None


class Sampler:
    """Background sampler. start() before the measured work, stop() after it."""

    def __init__(self, client_pid, output_base=None):
        self._client_pid = client_pid
        self._output_base = output_base
        self._stop_event = threading.Event()
        self._thread = threading.Thread(target=self._run, name="measure-sampler", daemon=True)
        self._lock = threading.Lock()
        self.samples = 0
        self.errors = 0
        self.peak_sum_mb = 0.0
        self.load1_max = 0.0
        self.swap_before_mb = None
        self.swap_peak_mb = None

    def start(self):
        self.swap_before_mb = swap_used_mb()
        self.swap_peak_mb = self.swap_before_mb
        self._sample()
        self._thread.start()

    def _run(self):
        while not self._stop_event.wait(INTERVAL_S):
            self._sample()

    def _sample(self):
        try:
            table = read_process_table()
            roots = set()
            pid = self._client_pid()
            if pid:
                roots.add(pid)
            if self._output_base:
                roots.update(p for p, info in table.items() if self._output_base in info.cmd)
                server = _server_pid(self._output_base)
                if server:
                    roots.add(server)
            selected = _descendants(table, roots)
            selected.update(p for p, info in table.items() if any(s in info.cmd for s in DART_PATTERNS))
            selected.discard(os.getpid())
            total_mb = sum(table[p].rss_kb for p in selected if p in table) / 1024.0
            swap = swap_used_mb()
            load = os.getloadavg()[0]
            with self._lock:
                self.samples += 1
                self.peak_sum_mb = max(self.peak_sum_mb, total_mb)
                self.swap_peak_mb = max(self.swap_peak_mb, swap)
                self.load1_max = max(self.load1_max, load)
        except Exception:  # sampling must never abort the measured command
            with self._lock:
                self.errors += 1

    def stop(self):
        self._stop_event.set()
        if self._thread.is_alive():
            self._thread.join(timeout=10)
        self._sample()
        with self._lock:
            return {
                "peak_sum_mb": round(self.peak_sum_mb, 1),
                "swap_before_mb": round(self.swap_before_mb or 0.0, 1),
                "swap_delta_mb": round(max(0.0, (self.swap_peak_mb or 0.0) - (self.swap_before_mb or 0.0)), 1),
                "load1_max": round(self.load1_max, 2),
                "samples": self.samples,
                "errors": self.errors,
            }
