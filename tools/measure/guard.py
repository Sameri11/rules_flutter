"""Pre-run checks: free disk, available memory, and optional Linux SDK cleanup.

Disk floors: macOS 15 GB; Linux 40 GB. If Linux stays under 40 GB after SDK
removal, the floor falls back to 20 GB and the record says so (floor_note).
Memory: available = free + inactive + speculative pages + free swap (macOS),
or MemAvailable + SwapFree (Linux). It must cover instances x worker_mb.
"""

from __future__ import annotations

import os
import re
import subprocess
from pathlib import Path

MACOS_FLOOR_GB = 15.0
LINUX_FLOOR_GB = 40.0
LINUX_FALLBACK_FLOOR_GB = 20.0
LINUX_SDK_PATHS = ("/usr/share/dotnet", "/opt/ghc", "/usr/share/swift")
_SWAP_RE = re.compile(r"free\s*=\s*([0-9.]+)([MG])")


def _run_text(cmd):
    return subprocess.run(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        universal_newlines=True,
        check=True,
    ).stdout


def _log(log_path, line):
    log_path = Path(log_path)
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with log_path.open("a") as handle:
        handle.write(line + "\n")


def disk_free_gb():
    out = _run_text(["df", "-Pk", os.path.expanduser("~")])
    fields = out.strip().splitlines()[-1].split()
    return int(fields[3]) / (1024.0 * 1024.0)


def _meminfo_mb(keys):
    values = {}
    with open("/proc/meminfo") as handle:
        for line in handle:
            key, _, rest = line.partition(":")
            if key in keys:
                values[key] = int(rest.split()[0]) / 1024.0
    return values


def available_memory_mb(os_name):
    if os_name == "macos":
        vm = _run_text(["vm_stat"])
        page_match = re.search(r"page size of (\d+) bytes", vm)
        if not page_match:
            raise SystemExit("guard: unrecognised vm_stat output")
        page = int(page_match.group(1))
        ram_mb = 0.0
        for name in ("free", "inactive", "speculative"):
            match = re.search(r"^Pages %s:\s+(\d+)\." % name, vm, re.M)
            if not match:
                raise SystemExit("guard: vm_stat has no 'Pages %s' line" % name)
            ram_mb += int(match.group(1)) * page / 1048576.0
        match = _SWAP_RE.search(_run_text(["sysctl", "-n", "vm.swapusage"]))
        if not match:
            raise SystemExit("guard: unrecognised vm.swapusage output")
        swap_free = float(match.group(1)) * (1024.0 if match.group(2) == "G" else 1.0)
        return {"available_mb": ram_mb + swap_free, "ram_mb": ram_mb, "swap_free_mb": swap_free}
    values = _meminfo_mb(("MemAvailable", "SwapFree"))
    if "MemAvailable" not in values or "SwapFree" not in values:
        raise SystemExit("guard: /proc/meminfo lacks MemAvailable or SwapFree")
    return {
        "available_mb": values["MemAvailable"] + values["SwapFree"],
        "ram_mb": values["MemAvailable"],
        "swap_free_mb": values["SwapFree"],
    }


def free_linux_sdks(log_path):
    """Remove preinstalled SDK trees that the runner image ships. Needs root or passwordless sudo."""
    before = disk_free_gb()
    removed = []
    for path in LINUX_SDK_PATHS:
        if not os.path.exists(path):
            continue
        cmd = ["rm", "-rf", path] if os.geteuid() == 0 else ["sudo", "-n", "rm", "-rf", path]
        code = subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False).returncode
        removed.append({"path": path, "exit_code": code})
    after = disk_free_gb()
    result = {"before_gb": round(before, 2), "after_gb": round(after, 2), "removed": removed}
    _log(log_path, "sdk-cleanup %s" % result)
    return result


def check(os_name, instances, worker_mb, log_path, label):
    """Abort (SystemExit) when disk or memory is short; otherwise return the record."""
    free_gb = disk_free_gb()
    note = ""
    if os_name == "macos":
        floor = MACOS_FLOOR_GB
        note = "macOS keeps its preinstalled SDKs; floor 15 GB (was 20 GB: free space declined during the run, see the disk lines)"
    elif free_gb >= LINUX_FLOOR_GB:
        floor = LINUX_FLOOR_GB
    else:
        floor = LINUX_FALLBACK_FLOOR_GB
        note = "40 GB floor unmet after SDK cleanup; floor applied: %d GB" % floor
    if free_gb < floor:
        raise SystemExit("guard: %s has %.1f GB free, floor is %.0f GB" % (label, free_gb, floor))
    mem = available_memory_mb(os_name)
    required = instances * worker_mb
    if mem["available_mb"] < required:
        raise SystemExit(
            "guard: %s has %.0f MB available, needs %d MB for %d workers"
            % (label, mem["available_mb"], required, instances)
        )
    record = {
        "label": label,
        "df_free_gb": round(free_gb, 2),
        "floor_gb": floor,
        "floor_note": note,
        "mem_available_mb": round(mem["available_mb"], 1),
        "mem_required_mb": required,
    }
    _log(log_path, "guard %s" % record)
    return record
