"""Memory, swap and load sampler for a measured process tree.

Every INTERVAL_S seconds the sampler sums the resident set of:
- the client process and its descendants,
- the Bazel server, found through the output base path in its command line or
  through server/server.pid.txt when present, and its descendants,
- every process whose command contains one of DART_PATTERNS.
Each test-kernel driver (DRIVER_MARKER) also has its own peak RSS, kept per process.
Swap occupancy comes from `sysctl -n vm.swapusage` on macOS and /proc/meminfo on Linux.
Swap traffic (pages swapped in and out) comes from /proc/vmstat on Linux only.
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
DRIVER_MARKER = "driver.dill"
DART_PATTERNS = (DRIVER_MARKER, "frontend_server", "dartaotruntime")
# Persistent test-kernel workers run as `dart driver.dill --persistent_worker`; a one-shot driver compile does not.
WORKER_MARKER = "--persistent_worker"
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


def swap_io_mb():
    """Cumulative (swapped in, swapped out) MB since boot, or None where /proc/vmstat is absent."""
    if sys.platform == "darwin":
        return None
    values = {}
    with open("/proc/vmstat") as handle:
        for line in handle:
            key, _, rest = line.partition(" ")
            if key in ("pswpin", "pswpout"):
                values[key] = int(rest)
    page_mb = os.sysconf("SC_PAGE_SIZE") / 1048576.0
    return (values["pswpin"] * page_mb, values["pswpout"] * page_mb)


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
        self.swapio_before = None
        self.swapio_after = None
        self.driver_peak_mb = 0.0
        self.driver_procs_max = 0
        self.kernel_procs_max = 0
        self.driver_pid_peak_kb = {}
        self.worker_pids = set()

    def start(self):
        self.swap_before_mb = swap_used_mb()
        self.swap_peak_mb = self.swap_before_mb
        self.swapio_before = swap_io_mb()
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
            drivers = [p for p, info in table.items() if any(s in info.cmd for s in DART_PATTERNS)]
            kernels = [p for p in drivers if DRIVER_MARKER in table[p].cmd]
            selected.update(drivers)
            selected.discard(os.getpid())
            total_mb = sum(table[p].rss_kb for p in selected if p in table) / 1024.0
            driver_mb = sum(table[p].rss_kb for p in drivers if p in table) / 1024.0
            swap = swap_used_mb()
            load = os.getloadavg()[0]
            with self._lock:
                self.samples += 1
                self.peak_sum_mb = max(self.peak_sum_mb, total_mb)
                self.swap_peak_mb = max(self.swap_peak_mb, swap)
                self.load1_max = max(self.load1_max, load)
                self.driver_peak_mb = max(self.driver_peak_mb, driver_mb)
                self.driver_procs_max = max(self.driver_procs_max, len(drivers))
                self.kernel_procs_max = max(self.kernel_procs_max, len(kernels))
                for p in kernels:
                    self.driver_pid_peak_kb[p] = max(self.driver_pid_peak_kb.get(p, 0), table[p].rss_kb)
                self.worker_pids.update(p for p in drivers if WORKER_MARKER in table[p].cmd)
        except Exception:  # sampling must never abort the measured command
            with self._lock:
                self.errors += 1

    def stop(self):
        self._stop_event.set()
        if self._thread.is_alive():
            self._thread.join(timeout=10)
        self._sample()
        self.swapio_after = swap_io_mb()
        with self._lock:
            each_mb = sorted(round(kb / 1024.0, 1) for kb in self.driver_pid_peak_kb.values())
            if self.swapio_before is None or self.swapio_after is None:
                swap_in_mb = swap_out_mb = None
            else:
                swap_in_mb = round(self.swapio_after[0] - self.swapio_before[0], 1)
                swap_out_mb = round(self.swapio_after[1] - self.swapio_before[1], 1)
            return {
                "peak_sum_mb": round(self.peak_sum_mb, 1),
                "swap_before_mb": round(self.swap_before_mb or 0.0, 1),
                "swap_delta_mb": round(max(0.0, (self.swap_peak_mb or 0.0) - (self.swap_before_mb or 0.0)), 1),
                "swap_in_mb": swap_in_mb,
                "swap_out_mb": swap_out_mb,
                "load1_max": round(self.load1_max, 2),
                "samples": self.samples,
                "driver_peak_mb": round(self.driver_peak_mb, 1),
                "driver_procs_max": self.driver_procs_max,
                "kernel_procs_max": self.kernel_procs_max,
                "driver_each_peak_mb": each_mb,
                "driver_max_mb": each_mb[-1] if each_mb else 0.0,
                "worker_pids": sorted(self.worker_pids),
                "errors": self.errors,
            }
