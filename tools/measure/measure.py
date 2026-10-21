#!/usr/bin/env python3
"""Measurement harness for test-kernel strategies on oinkoin and serverbox.

Subcommands:
  fetch-apps  clone an upstream app at its pinned commit, apply its patch, vendor
              dependencies, and wire the rules under test (unless --flutter-copy)
  wire        copy an app's wiring over an existing app root
  run         interleaved measurement matrix; writes records.jsonl and per-step logs,
              then the Linux hardening check
  manifest    SHA-256 manifest of the batch base build's dependency and kernel outputs
  check-salt  confirm MEASURE_SALT reaches the DartTestKernel action keys

Standard library only. Run from the rules checkout.
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import time
import uuid
from pathlib import Path

import bazel_io
import bep
import execlog
import guard
from sampler import Sampler

HERE = Path(__file__).resolve().parent
APPS_DIR = HERE / "apps"
DEFAULT_RULES_ROOT = HERE.parent.parent

UPSTREAM = {
    "oinkoin": {"url": "https://github.com/emavgl/oinkoin", "rev": "4878f5bfb636bb310f9e63252b39041eb1a62c19"},
    "serverbox": {"url": "https://github.com/lollipopkit/flutter_server_box", "rev": "a552973447cf55daa4486a5ef73801d40d0b0b8e"},
    "smooth": {"url": "https://github.com/openfoodfacts/smooth-app", "rev": "a286f0a932e28f4b15a3b03e6dc9eff9c14f35b1"},
}
APPS = tuple(sorted(UPSTREAM))
WORKER_MB = {"oinkoin": 1100, "serverbox": 1700, "smooth": 1700}
# Flutter project root, relative to the repository root, where it is not the root itself.
PUB_ROOT = {"smooth": "packages/smooth_app"}
WORKER_INSTANCES = {"macos": 2, "linux": 4}
RAM_FRACTION = 0.6
MODES = ("batch", "worker", "q5", "flutter")
BAZEL_MODES = ("batch", "worker", "q5")
MAX_ATTEMPTS = 2
MAX_REPEATS = 3
SWAP_GROWTH_LIMIT_MB = 1024.0
# Bazel exit 3 means the build succeeded and some tests failed; the failing set is recorded.
ACCEPTED_EXIT_CODES = (0, 3)
KERNEL_DIGEST_EXPR = 'mnemonic("DartTestKernel", deps(tests(//...)))'
# Kernel outputs of the measured targets. An explicit set, not `except //android/...`: smooth has no
# root android package, and query_targets already excludes the android bundle checks.
def manifest_expr(targets):
    return 'mnemonic("(DartTestDeps|DartLibKernel|DartTestKernel)", deps(set(%s)))' % " ".join(targets)
# Flutter test targets with a Dart test kernel, for the salt check (a non-Dart test has no kernel).
CHECK_TARGET = {"oinkoin": "//:test_csv_service_test", "serverbox": "//:test_app_tab_test"}

# One edit per step. Repeat r (1-based) applies new[r - 1]. Each old string must occur
# exactly once on the given line of the pristine file.
EDITS = {
    "oinkoin": {
        "test": {
            "path": "test/csv_service_test.dart",
            "line": 40,
            "old": "createCSVFromRecordList(records);",
            "new": [
                "createCSVFromRecordList(List.of(records));",
                "createCSVFromRecordList(List.unmodifiable(records));",
                "createCSVFromRecordList(records.toList());",
            ],
        },
        "wide": {
            "path": "lib/models/category.dart",
            "line": 121,
            "old": ": 0;",
            "new": [": 0 + 0;", ": 1 - 1;", ": 2 - 2;"],
        },
    },
    "serverbox": {
        "test": {
            "path": "test/app_tab_test.dart",
            "line": 9,
            "old": "expect(AppTab.defaultOrder, [",
            "new": [
                "expect(AppTab.defaultOrder.toList(), [",
                "expect(AppTab.defaultOrder.toList(growable: false), [",
                "expect(List.of(AppTab.defaultOrder), [",
            ],
        },
        "wide": {
            "path": "lib/data/model/app/tab.dart",
            "line": 78,
            "old": "return defaultOrder;",
            "new": ["return List.of(defaultOrder);", "return defaultOrder.toList();", "return [...defaultOrder];"],
        },
    },
    "smooth": {},
}


def log(message):
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%H:%M:%S")
    print("[measure %s] %s" % (stamp, message), file=sys.stderr, flush=True)


def log_first_error(job, name, log_file):
    """Log the first ERROR block of a failed bazel run."""
    lines = log_file.read_text(errors="replace").splitlines()
    starts = [i for i, line in enumerate(lines) if line.startswith("ERROR:")]
    if not starts:
        log("%s: no ERROR: line in the run log" % name)
        return
    log("%s first error:\n%s" % (name, "\n".join(lines[starts[0] : starts[0] + 40])))


def fail(message):
    raise SystemExit("measure: " + message)


def du_mb(path):
    """Apparent size of a tree in MB; -1 when du prints nothing."""
    out = subprocess.run(["du", "-sk", str(path)], capture_output=True, text=True).stdout.split()
    return int(out[0]) // 1024 if out else -1


def deleted_open_mb():
    """MB held by deleted files that are still open, from lsof; -1 when lsof is absent."""
    if shutil.which("lsof") is None:
        return -1
    out = subprocess.run(["lsof", "-nP", "+L1", "-Fs"], capture_output=True, text=True).stdout
    sizes = [int(line[1:]) for line in out.splitlines() if line[:1] == "s" and line[1:].isdigit()]
    return sum(sizes) // (1024 * 1024)


def disk_report(job, label):
    """Log the size of every tree the measurement writes, so a free-space decline can be attributed.

    `tmpdir` is the per-user temp dir (TMPDIR on macOS), where the test-kernel driver creates its
    request directories. `used` is the volume's used space, to set against the sum of the trees.
    """
    tmpdir = Path(os.environ.get("TMPDIR") or "/tmp")
    trees = [
        ("scratch", job.scratch),
        ("output-bases", job.scratch / "ob"),
        ("disk-caches", job.scratch / "disk"),
        ("snapshot", job.snapshot),
        ("bazel-cache", Path.home() / ".cache" / "bazel"),
        ("bazel-cache-macos", Path.home() / "Library" / "Caches" / "bazel"),
        ("pub-cache", Path(os.environ.get("PUB_CACHE") or Path.home() / ".pub-cache")),
        ("tmp", Path("/tmp")),
        ("tmpdir", tmpdir),
    ]
    sizes = []
    for name, path in trees:
        if not path.exists():
            sizes.append("%s=absent" % name)
            continue
        sizes.append("%s=%dMB" % (name, du_mb(path)))
    used = shutil.disk_usage(str(job.scratch)).used / 1024 ** 3
    log(
        "disk %s: free=%.1f GB used=%.1f GB deleted-open=%dMB %s"
        % (label, guard.disk_free_gb(), used, deleted_open_mb(), " ".join(sizes))
    )


def current_os():
    system = platform.system()
    if system == "Darwin":
        return "macos"
    if system == "Linux":
        return "linux"
    fail("unsupported host: %s" % system)


def _git_env():
    env = dict(os.environ)
    env["GIT_TERMINAL_PROMPT"] = "0"
    return env


def _git(args, cwd=None):
    subprocess.run(["git", *args], cwd=None if cwd is None else str(cwd), check=True, env=_git_env())


def _git_head(cwd):
    return subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=str(cwd),
        stdout=subprocess.PIPE,
        universal_newlines=True,
        check=True,
    ).stdout.strip()


def _check_head(repo, rev):
    head = _git_head(repo)
    if not head.lower().startswith(rev.lower()):
        fail("%s is at %s, expected %s" % (repo, head, rev))


def load_vendored(app):
    path = APPS_DIR / app / "vendored.json"
    if not path.is_file():
        fail("missing %s" % path)
    doc = json.loads(path.read_text())
    if isinstance(doc, dict):
        if "vendored" not in doc:
            fail("%s has no 'vendored' list" % path)
        entries = doc["vendored"]
    else:
        entries = doc
    if not isinstance(entries, list):
        fail("%s must hold a list of entries" % path)
    for entry in entries:
        for key in ("path", "url", "rev"):
            if not isinstance(entry.get(key), str) or not entry[key]:
                fail("%s: an entry lacks %s" % (path, key))
        rel = Path(entry["path"])
        if rel.is_absolute() or ".." in rel.parts:
            fail("%s: path escapes the app root: %s" % (path, entry["path"]))
    return entries


def _fetch_rev(url, dest, rev):
    """Shallow-fetch one pinned commit into a new repository at dest."""
    dest.mkdir(parents=True, exist_ok=True)
    _git(["init", "--quiet"], cwd=dest)
    _git(["remote", "add", "origin", url], cwd=dest)
    _git(["fetch", "--quiet", "--depth", "1", "origin", rev], cwd=dest)
    _git(["checkout", "--quiet", "--detach", "FETCH_HEAD"], cwd=dest)


def fetch_upstream(app, dest):
    spec = UPSTREAM[app]
    _fetch_rev(spec["url"], dest, spec["rev"])
    _check_head(dest, spec["rev"])
    patch = APPS_DIR / app / "upstream.patch"
    if not patch.is_file():
        fail("missing %s" % patch)
    _git(["apply", "--whitespace=nowarn", str(patch)], cwd=dest)
    if (dest / ".gitmodules").is_file():
        _git(["submodule", "update", "--init", "--recursive", "--depth", "1", "--quiet"], cwd=dest)
    for patch in sorted((APPS_DIR / app).glob("submodule-*.patch")):
        # A submodule patch is named submodule-<name>.patch and applies to packages/<name>.
        sub = dest / "packages" / patch.stem[len("submodule-"):]
        if not (sub / ".git").exists():
            fail("submodule checkout missing for %s" % patch.name)
        _git(["apply", "--whitespace=nowarn", str(patch)], cwd=sub)
    for entry in load_vendored(app):
        target = dest / entry["path"]
        if target.exists() and any(target.iterdir()):
            fail("vendored path is already populated: %s" % entry["path"])
        target.parent.mkdir(parents=True, exist_ok=True)
        _fetch_rev(entry["url"], target, entry["rev"])
        _check_head(target, entry["rev"])
        shutil.rmtree(target / ".git")


def wire_app(app, dest):
    source = APPS_DIR / app / "wiring"
    if not source.is_dir():
        fail("missing %s" % source)
    copied = 0
    for path in sorted(p for p in source.rglob("*") if p.is_file()):
        target = dest / path.relative_to(source)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, target)
        copied += 1
    return copied


def _flutter_pub_get(dest):
    """Run `flutter pub get`: the plugins extension reads .flutter-plugins-dependencies from it."""
    subprocess.run(["flutter", "pub", "get"], cwd=str(dest), check=True)


def fetch_app(app, dest, wire):
    if dest.exists():
        fail("destination exists: %s" % dest)
    dest.parent.mkdir(parents=True, exist_ok=True)
    fetch_upstream(app, dest)
    if wire:
        log("wired %d files into %s" % (wire_app(app, dest), dest))
        _flutter_pub_get(dest / PUB_ROOT.get(app, "."))


def cmd_fetch_apps(args):
    fetch_app(args.app, Path(args.dest).resolve(), wire=not args.flutter_copy)
    return 0


def cmd_wire(args):
    dest = Path(args.dest).resolve()
    if not dest.is_dir():
        fail("no app root at %s" % dest)
    print("wired %d files" % wire_app(args.app, dest))
    return 0


def _sysctl(name):
    try:
        return subprocess.run(
            ["sysctl", "-n", name],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            universal_newlines=True,
            check=True,
        ).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return ""


def _meminfo_kb(key):
    with open("/proc/meminfo") as handle:
        for line in handle:
            if line.startswith(key + ":"):
                return int(line.split()[1])
    return None


def _cpu_model():
    with open("/proc/cpuinfo") as handle:
        for line in handle:
            if line.startswith("model name"):
                return line.partition(":")[2].strip()
    return ""


def host_info(os_name):
    if os_name == "macos":
        ram_mb = int(_sysctl("hw.memsize") or 0) // (1024 * 1024)
        cpu = _sysctl("machdep.cpu.brand_string")
    else:
        ram_mb = (_meminfo_kb("MemTotal") or 0) // 1024
        cpu = _cpu_model()
    return {
        "image_version": os.environ.get("ImageVersion") or os.environ.get("ImageOS") or "",
        "cpu_model": cpu,
        "nproc": os.cpu_count(),
        "ram_mb": ram_mb,
    }


def dir_mb(path):
    if not path or not Path(path).exists():
        return None
    out = subprocess.run(
        ["du", "-sk", str(path)],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        universal_newlines=True,
        check=False,
    ).stdout
    try:
        return round(int(out.split()[0]) / 1024.0, 1)
    except (IndexError, ValueError):
        return None


def resolve_rc(explicit):
    if explicit:
        path = Path(explicit).resolve()
        if not path.is_file():
            fail("remote rc not found: %s" % path)
        return str(path)
    runner_temp = os.environ.get("RUNNER_TEMP")
    if runner_temp and (Path(runner_temp) / "remote.bazelrc").is_file():
        return str(Path(runner_temp) / "remote.bazelrc")
    return None


class Job:
    """Paths and host facts shared by every step of one invocation."""

    def __init__(self, *, app, os_name, rules_root, scratch, out, remote_rc, run_id):
        if os_name not in WORKER_INSTANCES:
            fail("unknown --os %s" % os_name)
        self.app = app
        self.os = os_name
        self.run_id = run_id
        self.app_dir = Path(rules_root).resolve() / "_apps" / app
        self.scratch = Path(scratch).resolve()
        self.out = Path(out).resolve()
        self.rc = resolve_rc(remote_rc)
        self.instances = WORKER_INSTANCES[os_name]
        self.host = host_info(os_name)
        if self.host["ram_mb"] <= 0:
            fail("cannot read the RAM size")
        self.local_ram_mb = int(self.host["ram_mb"] * RAM_FRACTION)
        self.worker_mb = WORKER_MB[app]
        self.edits = EDITS[app]
        self.pristine = self.scratch / "pristine" / app
        self.snapshot = self.scratch / "snap"
        self.targets = []

    def check_platform(self):
        expected = "Linux" if self.os == "linux" else "Darwin"
        if platform.system() != expected:
            fail("--os %s needs a %s host" % (self.os, expected))

    def check_wired(self):
        if not (self.app_dir / "MODULE.bazel").is_file():
            fail("%s is not wired; run fetch-apps first" % self.app_dir)

    def preflight(self, label):
        disk_report(self, label)
        return guard.check(self.os, self.instances, self.worker_mb, self.out / "guard.log", label)


def mode_flags(mode, instances):
    if mode == "batch":
        return ["--strategy=DartTestKernel=sandboxed", "--strategy=DartLibKernel=sandboxed"]
    flags = [
        "--strategy=DartTestKernel=worker",
        "--noworker_multiplex",
        "--worker_max_instances=DartTestKernel=%d" % instances,
        "--strategy=DartLibKernel=sandboxed",
    ]
    if mode == "q5":
        flags.append("--@rules_flutter//flutter:test_kernel_deps=split")
    return flags


def analysis_flags(flags, salt):
    return list(flags) + ["--action_env=MEASURE_SALT=%s" % salt]


def mode_order(rep):
    shift = (rep - 1) % len(MODES)
    return MODES[shift:] + MODES[:shift]


def rel(job, path):
    return str(Path(path).relative_to(job.out))


def teardown(job, output_base, disk=None):
    bazel_io.shutdown(output_base, job.rc, job.app_dir)
    if output_base.exists():
        log("output base %s: %d MB" % (output_base.name, du_mb(output_base)))
    bazel_io.remove_tree(output_base)
    if disk is not None:
        bazel_io.remove_tree(disk)


def query_targets(job):
    ob = job.scratch / "ob" / "query"
    teardown(job, ob)
    try:
        full = bazel_io.query_test_targets(ob, job.rc, job.app_dir)
    finally:
        teardown(job, ob)
    # The Android bundle check is test-class but not a Dart test; it fails on the runner's
    # native assets, so it is excluded from measurement and the exclusion is recorded.
    targets = [t for t in full if not bazel_io.is_android_label(t)]
    excluded = sorted(set(full) - set(targets))
    (job.out / ("excluded-targets-%s.txt" % job.app)).write_text("\n".join(excluded) + "\n")
    if not targets:
        fail("tests(//...) is empty for %s" % job.app)
    job.targets = targets
    return targets


def _edit_index(lines, spec):
    idx = spec["line"] - 1
    if idx >= len(lines) or lines[idx].count(spec["old"]) != 1:
        fail("%s line %d does not contain the expected text exactly once" % (spec["path"], spec["line"]))
    return idx


def make_pristine(job):
    for spec in job.edits.values():
        source = job.app_dir / spec["path"]
        _edit_index(source.read_text(encoding="utf-8").split("\n"), spec)
        target = job.pristine / spec["path"]
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)


def apply_edit(job, step, index):
    spec = job.edits[step]
    path = job.app_dir / spec["path"]
    lines = path.read_bytes().decode("utf-8").split("\n")
    idx = _edit_index(lines, spec)
    lines[idx] = lines[idx].replace(spec["old"], spec["new"][index])
    path.write_bytes("\n".join(lines).encode("utf-8"))


def restore_file(job, step):
    spec = job.edits[step]
    shutil.copy2(job.pristine / spec["path"], job.app_dir / spec["path"])


def restore_edits(job):
    for step in job.edits:
        restore_file(job, step)


def timed_process(cmd, cwd, stdout_path, stderr_path, output_base=None):
    """Run cmd with the sampler attached. stderr_path None merges stderr into stdout."""
    holder = {"pid": None}
    sampler = Sampler(lambda: holder["pid"], output_base=str(output_base) if output_base else None)
    stdout_path.parent.mkdir(parents=True, exist_ok=True)
    code = None
    wall = None
    with stdout_path.open("wb") as stdout_handle:
        stderr_handle = None
        try:
            if stderr_path is not None:
                stderr_path.parent.mkdir(parents=True, exist_ok=True)
                stderr_handle = stderr_path.open("wb")
            started = time.monotonic()
            proc = subprocess.Popen(
                cmd,
                cwd=str(cwd),
                stdout=stdout_handle,
                stderr=stderr_handle if stderr_handle is not None else subprocess.STDOUT,
            )
            holder["pid"] = proc.pid
            sampler.start()
            code = proc.wait()
            wall = time.monotonic() - started
        finally:
            mem = sampler.stop()
            if stderr_handle is not None:
                stderr_handle.close()
    return {"exit_code": code, "wall_s": round(wall, 3), "mem": mem}


def bazel_test(job, *, ob, disk, salt, flags, name, targets=None):
    """One `bazel test --keep_going` with the measurement options. Returns the run dict."""
    targets = job.targets if targets is None else targets
    bep_file = job.out / "bep" / (name + ".json")
    profile_file = job.out / "profile" / (name + ".profile.gz")
    execlog_file = job.out / "execlog" / (name + ".jsonl")
    for path in (bep_file, profile_file, execlog_file):
        path.parent.mkdir(parents=True, exist_ok=True)
    args = ["test", "--keep_going"]
    if disk is not None:
        args.append("--disk_cache=%s" % disk)
    args += [
        "--action_env=MEASURE_SALT=%s" % salt,
        "--remote_download_outputs=all",
        "--jobs=%d" % job.instances,
        "--local_resources=CPU=%d" % job.instances,
        "--local_resources=MEMORY=%d" % job.local_ram_mb,
        "--build_event_json_file=%s" % bep_file,
        "--profile=%s" % profile_file,
        "--execution_log_json_file=%s" % execlog_file,
    ]
    args += list(flags) + list(targets)
    log_file = job.out / "logs" / (name + ".log")
    run = timed_process(bazel_io.bazel_cmd(ob, job.rc, *args), job.app_dir, log_file, None, output_base=ob)
    if run["exit_code"] not in ACCEPTED_EXIT_CODES:
        log_first_error(job, name, log_file)
    run["files"] = {
        "log": rel(job, log_file),
        "bep": rel(job, bep_file),
        "profile": rel(job, profile_file),
        "execlog": rel(job, execlog_file),
    }
    run["salt"] = salt
    run["flags"] = list(flags)
    return run


def ensure_snapshot(job):
    """Untimed warm-up build. Salt-free actions (pub, pubspec, test deps) are reused by the cold step.

    Kernel actions carry the run salt (`warm` here), so the snapshot holds no kernel entry that a measured run can hit.
    """
    if job.snapshot.is_dir():
        return
    restore_edits(job)
    job.snapshot.mkdir(parents=True)
    ob = job.scratch / "ob" / "warm"
    try:
        run = bazel_test(
            job,
            ob=ob,
            disk=job.snapshot,
            salt="warm",
            flags=mode_flags("batch", job.instances),
            name="warm",
        )
    finally:
        teardown(job, ob)
    if run["exit_code"] not in ACCEPTED_EXIT_CODES:
        fail("warm-up build exited %s; see logs/warm.log" % run["exit_code"])
    log("warm-up complete")


def run_reasons(run):
    reasons = []
    if run["exit_code"] not in ACCEPTED_EXIT_CODES:
        reasons.append("exit code %s" % run["exit_code"])
    mem = run["mem"]
    if mem["swap_delta_mb"] > SWAP_GROWTH_LIMIT_MB:
        reasons.append("swap grew %.0f MB" % mem["swap_delta_mb"])
    # load1 is recorded per run but not a validity rule on CI: a dedicated runner's load is the workload.
    return reasons


def kernel_digest(job, ob, salt, flags):
    try:
        entries = bazel_io.output_digests(
            ob, job.rc, job.app_dir, KERNEL_DIGEST_EXPR, analysis_flags(flags, salt)
        )
    except bazel_io.BazelError as err:
        return {"digest": None, "count": 0, "error": str(err)}
    kernels = [e for e in entries if e["mnemonic"] == "DartTestKernel"]
    if not kernels:
        return {"digest": None, "count": 0, "error": "no DartTestKernel outputs"}
    return {"digest": bazel_io.entries_digest(kernels), "count": len(kernels), "error": None}


def common_record(job, mode, rep, attempt, step, run, guard_record):
    mem = run["mem"]
    return {
        "app": job.app,
        "os": job.os,
        "mode": mode,
        "rep": rep,
        "step": step,
        "attempt": attempt,
        "rerun": attempt > 1,
        "superseded": False,
        "host": {
            "image_version": job.host["image_version"],
            "cpu_model": job.host["cpu_model"],
            "nproc": job.host["nproc"],
            "ram_mb": job.host["ram_mb"],
            "df_free_gb": guard_record["df_free_gb"],
            "swap_mb_before": mem["swap_before_mb"],
        },
        "mem": {
            "peak_sum_mb": mem["peak_sum_mb"],
            "swap_delta_mb": mem["swap_delta_mb"],
            "load1_max": mem["load1_max"],
            "samples": mem["samples"],
            "errors": mem["errors"],
        },
        "guard": guard_record,
        "wall_s": run["wall_s"],
        "exit_code": run["exit_code"],
        "files": run["files"],
    }


def bazel_record(job, mode, rep, attempt, step, run, digest, guard_record):
    bep_info = bep.parse_bep(job.out / run["files"]["bep"])
    profile = bep.parse_profile(job.out / run["files"]["profile"])
    stats = execlog.parse_execlog(job.out / run["files"]["execlog"])
    reasons = run_reasons(run) + execlog.check(stats, mode, step)
    if digest["error"]:
        reasons.append("kernel digest: %s" % digest["error"])
    rec = common_record(job, mode, rep, attempt, step, run, guard_record)
    rec.update(
        {
            "profile": {
                key: profile[key]
                for key in ("fetch_s", "analysis_s", "execution_s", "loading_s", "analysis_execution_s")
            },
            "actions": {
                "created": bep_info["actions_created"],
                "executed": bep_info["actions_executed"],
                "remote_cache_hits": bep_info["remote_cache_hits"],
            },
            "bytes": {"up": bep_info["bytes_sent"], "down": bep_info["bytes_recv"]},
            "spawns": execlog.summarize(stats),
            "test_kernel_digest": digest["digest"],
            "test_kernel_count": digest["count"],
            "salt": run["salt"],
            "failing_tests": bep_info["failing_tests"],
            "flags": run["flags"],
            "valid": not reasons,
            "invalid_reasons": reasons,
        }
    )
    return rec


def step_name(mode, rep, attempt, step):
    return "%s-rep%d-a%d-%s" % (mode, rep, attempt, step)


def run_bazel_attempt(job, mode, rep, attempt):
    flags = mode_flags(mode, job.instances)
    salt = "%s-%s-rep%d" % (job.run_id, mode, rep) + ("" if attempt == 1 else "-a%d" % attempt)
    ob = job.scratch / "ob" / ("%s-rep%d" % (mode, rep))
    disk = job.scratch / "disk" / ("%s-rep%d" % (mode, rep))
    teardown(job, ob, disk)
    if disk.exists():
        bazel_io.remove_tree(disk)
    bazel_io.clone_tree(job.snapshot, disk)
    restore_edits(job)
    guard_record = job.preflight(step_name(mode, rep, attempt, "start"))
    records = []
    try:
        run = bazel_test(
            job, ob=ob, disk=disk, salt=salt, flags=flags, name=step_name(mode, rep, attempt, "cold")
        )
        digest = kernel_digest(job, ob, salt, flags)
        records.append(bazel_record(job, mode, rep, attempt, "cold", run, digest, guard_record))
        for step in ("wide", "test"):
            apply_edit(job, step, rep - 1)
            try:
                run = bazel_test(
                    job, ob=ob, disk=disk, salt=salt, flags=flags, name=step_name(mode, rep, attempt, step)
                )
                digest = kernel_digest(job, ob, salt, flags)
            finally:
                restore_file(job, step)
            records.append(bazel_record(job, mode, rep, attempt, step, run, digest, guard_record))
    finally:
        restore_edits(job)
        teardown(job, ob, disk)
    return records


def flutter_record(job, rep, attempt, step, run, guard_record, counts):
    reasons = run_reasons(run)
    if counts is not None and run["exit_code"] == 1 and counts["done_success"] is not None:
        # flutter test exits 1 when tests fail; the run is valid and its failing set is recorded.
        reasons = [r for r in reasons if not r.startswith("exit code")]
    if counts is not None:
        if counts["done_success"] is None:
            reasons.append("flutter test emitted no done event")
    rec = common_record(job, "flutter", rep, attempt, step, run, guard_record)
    rec.update(
        {
            "profile": None,
            "actions": None,
            "bytes": None,
            "spawns": None,
            "flutter": counts,
            "valid": not reasons,
            "invalid_reasons": reasons,
        }
    )
    return rec


def parse_machine(path):
    counts = {
        "passed": 0,
        "failed": 0,
        "skipped": 0,
        "done_success": None,
        "unparsed_lines": 0,
    }
    if not path.is_file():
        return counts
    names = {}
    failing = set()
    for line in path.read_text(errors="replace").splitlines():
        if not line.strip():
            continue
        try:
            value = json.loads(line)
        except ValueError:
            counts["unparsed_lines"] += 1
            continue
        for event in value if isinstance(value, list) else [value]:
            if not isinstance(event, dict):
                continue
            kind = event.get("type")
            if kind == "testDone" and not event.get("hidden", False):
                if event.get("skipped"):
                    counts["skipped"] += 1
                elif event.get("result") == "success":
                    counts["passed"] += 1
                else:
                    counts["failed"] += 1
                    failing.add(names.get(event.get("testID"), "?"))
            elif kind == "testStart":
                test = event.get("test") or {}
                names[test.get("id")] = test.get("name", "?")
            elif kind == "done":
                counts["done_success"] = bool(event.get("success"))
    counts["total"] = counts["passed"] + counts["failed"] + counts["skipped"]
    counts["failing"] = sorted(failing)
    return counts


def run_flutter_attempt(job, rep, attempt):
    guard_record = job.preflight("flutter-rep%d-a%d-start" % (rep, attempt))
    attempt_dir = job.scratch / "flutter" / ("rep%d-a%d" % (rep, attempt))
    if attempt_dir.exists():
        bazel_io.remove_tree(attempt_dir)
    clone = attempt_dir / job.app
    fetch_app(job.app, clone, wire=False)
    name = "flutter-rep%d-a%d" % (rep, attempt)
    records = []
    try:
        pub_log = job.out / "logs" / (name + "-pub-get.log")
        pub = timed_process(["flutter", "pub", "get"], clone, pub_log, None)
        pub["files"] = {"log": rel(job, pub_log)}
        records.append(flutter_record(job, rep, attempt, "pubget", pub, guard_record, None))
        machine = job.out / "flutter" / (name + ".machine.jsonl")
        test_log = job.out / "logs" / (name + "-test.log")
        test = timed_process(["flutter", "test", "test/", "--machine"], clone, machine, test_log)
        test["files"] = {"log": rel(job, test_log), "machine": rel(job, machine)}
        records.append(flutter_record(job, rep, attempt, "flutter", test, guard_record, parse_machine(machine)))
    finally:
        bazel_io.remove_tree(attempt_dir)
    return records


def append_records(job, records):
    with (job.out / "records.jsonl").open("a") as handle:
        for rec in records:
            handle.write(json.dumps(rec, sort_keys=True) + "\n")


def attempt_loop(job, label, run_attempt):
    attempts = []
    for attempt in range(1, MAX_ATTEMPTS + 1):
        records = run_attempt(attempt)
        attempts.append(records)
        reasons = sorted({reason for r in records for reason in r["invalid_reasons"]})
        verdict = "valid" if not reasons else "invalid: " + "; ".join(reasons)
        log("%s attempt %d: %s" % (label, attempt, verdict))
        if verdict == "valid":
            break
    if len(attempts) > 1:
        for rec in attempts[0]:
            rec["superseded"] = True
    for records in attempts:
        append_records(job, records)


def run_bazel_mode(job, mode, rep):
    attempt_loop(
        job,
        "%s rep%d" % (mode, rep),
        lambda attempt: run_bazel_attempt(job, mode, rep, attempt),
    )


def run_flutter_mode(job, rep):
    attempt_loop(job, "flutter rep%d" % rep, lambda attempt: run_flutter_attempt(job, rep, attempt))


def driver_log_counts(output_base):
    """Driver request lines per worker log: working directory and visible hardening probes per request."""
    cwd_pattern = re.compile(r"cwd=(.*?), probes=(\d+)")
    lines = 0
    legacy_sandboxed = 0
    in_worker_dir = 0
    probes_seen = 0
    logs = 0
    for log_file in sorted((Path(output_base) / "bazel-workers").glob("*DartTestKernel*.log")):
        logs += 1
        for line in log_file.read_text(errors="replace").splitlines():
            if "test_kernel_driver:" not in line:
                continue
            lines += 1
            if "sandboxed=true" in line:
                legacy_sandboxed += 1
            found = cwd_pattern.search(line)
            if found:
                if "/bazel-workers/" in found.group(1):
                    in_worker_dir += 1
                probes_seen += int(found.group(2))
    return {
        "logs": logs,
        "lines": lines,
        "legacy_sandboxed_lines": legacy_sandboxed,
        "lines_in_worker_dir": in_worker_dir,
        "probes_seen": probes_seen,
    }


def hardening_worker_flags(instances):
    return [
        "--strategy=DartTestKernel=worker",
        "--noworker_multiplex",
        "--worker_sandboxing",
        "--experimental_worker_sandbox_hardening",
        "--worker_max_instances=DartTestKernel=%d" % instances,
    ]


# Test targets whose worker build runs a Dart test kernel. Pinned: the first query result
# is not guaranteed to build one (serverbox's first target built zero kernels).
HARDENING_TARGET = {"oinkoin": "//:test_csv_import_integration_test", "serverbox": "//:test_app_tab_test"}


def hardening_target(job):
    target = HARDENING_TARGET[job.app]
    if target not in job.targets:
        fail("hardening target %s is not a test target of %s" % (target, job.app))
    return target


def userns_restriction():
    """Value of kernel.apparmor_restrict_unprivileged_userns, or None where the key does not exist."""
    out = subprocess.run(
        ["sysctl", "-n", "kernel.apparmor_restrict_unprivileged_userns"],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        universal_newlines=True,
        check=False,
    ).stdout.strip()
    return out or None


def set_userns_restriction(value):
    subprocess.run(
        ["sudo", "-n", "sysctl", "-w", "kernel.apparmor_restrict_unprivileged_userns=%s" % value],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=True,
    )


def hardening(job):
    """Hardening with the user-namespace restriction lowered for its worker-sandbox builds, then restored.

    Ubuntu 24.04 runners set the restriction to 1, which stops linux-sandbox from creating namespaces;
    the worker-sandbox builds then fail before any request. The previous value is recorded.
    """
    previous = userns_restriction()
    lowered = previous == "1"
    if lowered:
        set_userns_restriction("0")
    try:
        return run_hardening(job, previous)
    finally:
        if lowered:
            set_userns_restriction("1")


def run_hardening(job, previous):
    """Worker-sandbox hardening (Linux): byte identity against a sandboxed build, and driver sandbox flags."""
    target = hardening_target(job)
    builds = {}
    for name, flags in (
        ("worker", hardening_worker_flags(job.instances)),
        ("sandboxed", ["--strategy=DartTestKernel=sandboxed"]),
    ):
        salt = "%s-hard-%s" % (job.run_id, name)
        ob = job.scratch / "ob" / ("hardening-" + name)
        teardown(job, ob)
        probe = None
        try:
            if name == "worker":
                # A workspace-root file: Bazel links it into the execroot at build start. An undeclared file
                # placed directly in the execroot is removed before the build runs.
                probe = "hardening-probe-%s" % salt
                (job.app_dir / probe).write_text("undeclared\n")
            run = bazel_test(
                job,
                ob=ob,
                disk=None,
                salt=salt,
                flags=flags,
                name="hardening-" + name,
                targets=[target],
            )
            stats = execlog.parse_execlog(job.out / run["files"]["execlog"])
            probe_present = None
            if probe is not None:
                execroot = Path(bazel_io.info(ob, job.rc, job.app_dir, "execution_root"))
                probe_present = os.path.lexists(execroot / probe)
            build = {
                "exit_code": run["exit_code"],
                "failing_tests": bep.parse_bep(job.out / run["files"]["bep"])["failing_tests"],
                "salt": salt,
                "flags": flags,
                "kernel": execlog.summarize(stats)["DartTestKernel"],
                "driver": driver_log_counts(ob) if name == "worker" else None,
                "probe": probe,
                "probe_present": probe_present,
                "outputs": None,
                "error": None,
            }
            try:
                build["outputs"] = bazel_io.output_digests(
                    ob,
                    job.rc,
                    job.app_dir,
                    'mnemonic("DartTestKernel", deps(%s))' % target,
                    analysis_flags(flags, salt),
                )
            except bazel_io.BazelError as err:
                build["error"] = str(err)
        finally:
            if probe is not None:
                (job.app_dir / probe).unlink(missing_ok=True)
            teardown(job, ob)
        builds[name] = build
    worker = builds["worker"]
    sandboxed = builds["sandboxed"]
    driver = worker["driver"] or {}
    checks = {
        "builds_exit_zero": worker["exit_code"] in ACCEPTED_EXIT_CODES and sandboxed["exit_code"] in ACCEPTED_EXIT_CODES,
        "outputs_identical": bool(worker["outputs"]) and worker["outputs"] == sandboxed["outputs"],
        "same_failing_tests": worker["failing_tests"] == sandboxed["failing_tests"],
        "worker_runners": worker["kernel"]["count"] > 0
        and all(execlog.is_worker_runner(r) for r in worker["kernel"]["runners"])
        and worker["kernel"]["cache_hit"] == 0,
        "driver_in_worker_dir": driver.get("lines", 0) > 0 and driver.get("lines_in_worker_dir") == driver.get("lines"),
        "probe_hidden_from_driver": driver.get("lines", 0) > 0 and driver.get("probes_seen") == 0,
        "probe_in_execroot": worker["probe_present"] is True,
    }
    # Superseded: WorkRequest.sandbox_dir is unset for singleplex workers (their working directory is the sandbox).
    legacy_passed = driver.get("lines", 0) > 0 and driver.get("legacy_sandboxed_lines") == driver.get("lines")
    doc = {
        "passed": all(checks.values()),
        "target": target,
        "checks": checks,
        "superseded_checks": {
            "driver_sandboxed": {
                "passed": legacy_passed,
                "reason": "read sandboxDir from the request; singleplex workers do not receive it",
            },
        },
        "builds": builds,
        "userns_restriction": previous,
    }
    (job.out / "hardening.json").write_text(json.dumps(doc, indent=2, sort_keys=True) + "\n")
    failed = sorted(name for name, ok in checks.items() if not ok)
    summary = {
        name: {
            "exit_code": build["exit_code"],
            "kernel": build["kernel"],
            "driver": build["driver"],
            "error": (build["error"] or "")[:400],
        }
        for name, build in builds.items()
    }
    log("hardening: failed checks: %s; %s" % (", ".join(failed) or "none", json.dumps(summary, sort_keys=True)))
    log("hardening %s" % ("passed" if doc["passed"] else "FAILED"))
    return doc


def record_host_state(job, cleanup):
    ob = job.scratch / "ob" / "host-state"
    teardown(job, ob)
    try:
        repo_cache = bazel_io.info(ob, job.rc, job.app_dir, "repository_cache")
    finally:
        teardown(job, ob)
    pub_cache = Path(os.environ.get("PUB_CACHE") or Path.home() / ".pub-cache")
    precache_log = job.out / "logs" / "flutter-precache.log"
    precache_log.parent.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    with precache_log.open("wb") as handle:
        code = subprocess.run(
            ["flutter", "precache", "--android"],
            stdout=handle,
            stderr=subprocess.STDOUT,
            check=False,
        ).returncode
    state = {
        "host": job.host,
        "remote_cache": job.rc is not None,
        "bazel_repository_cache": repo_cache,
        "bazel_repository_cache_mb": dir_mb(repo_cache),
        "pub_cache_mb": dir_mb(pub_cache),
        "flutter_precache_android": {
            "exit_code": code,
            "wall_s": round(time.monotonic() - started, 3),
        },
        "linux_sdk_cleanup": cleanup,
    }
    (job.out / "host-state.json").write_text(json.dumps(state, indent=2, sort_keys=True) + "\n")


def write_run_config(job, args):
    config = {
        "app": job.app,
        "os": job.os,
        "run_id": job.run_id,
        "repeats": args.repeats,
        "rotation": [mode_order(r) for r in range(1, args.repeats + 1)],
        "instances": job.instances,
        "local_ram_mb": job.local_ram_mb,
        "remote_cache": job.rc is not None,
        "bazel_modes": {mode: mode_flags(mode, job.instances) for mode in BAZEL_MODES},
        "edits": {
            step: {"path": spec["path"], "line": spec["line"], "values": spec["new"]}
            for step, spec in job.edits.items()
        },
        "free_preinstalled_sdks": args.free_preinstalled_sdks,
        "max_attempts": MAX_ATTEMPTS,
    }
    (job.out / "run-config.json").write_text(json.dumps(config, indent=2, sort_keys=True) + "\n")


def cmd_run(args):
    if not 1 <= args.repeats <= MAX_REPEATS:
        fail("--repeats must be between 1 and %d" % MAX_REPEATS)
    job = Job(
        app=args.app,
        os_name=args.os,
        rules_root=args.rules_root,
        scratch=args.scratch,
        out=args.out,
        remote_rc=args.remote_rc,
        run_id=args.salt,
    )
    job.check_platform()
    job.check_wired()
    job.out.mkdir(parents=True, exist_ok=True)
    job.scratch.mkdir(parents=True, exist_ok=True)
    cleanup = None
    if job.os == "linux" and args.free_preinstalled_sdks == "yes":
        cleanup = guard.free_linux_sdks(job.out / "guard.log")
    record_host_state(job, cleanup)
    targets = query_targets(job)
    (job.out / ("targets-%s.txt" % job.app)).write_text("\n".join(targets) + "\n")
    write_run_config(job, args)
    make_pristine(job)
    ensure_snapshot(job)
    for rep in range(1, args.repeats + 1):
        for mode in mode_order(rep):
            if mode == "flutter":
                run_flutter_mode(job, rep)
            else:
                run_bazel_mode(job, mode, rep)
    if job.os == "linux":
        # A failed hardening check is a result: hardening.json records it and the run completes with its artifacts.
        hardening(job)
    log("run complete")
    return 0


def cmd_manifest(args):
    salt = args.salt or "manifest-" + uuid.uuid4().hex[:12]
    job = Job(
        app=args.app,
        os_name=current_os(),
        rules_root=args.rules_root,
        scratch=args.scratch,
        out=Path(args.scratch) / "tool-logs",
        remote_rc=args.remote_rc,
        run_id=salt,
    )
    job.check_wired()
    job.out.mkdir(parents=True, exist_ok=True)
    query_targets(job)
    flags = mode_flags("batch", job.instances)
    ob = job.scratch / "ob" / "manifest"
    out_path = Path(args.out).resolve()
    kernel_dir = out_path.parent / ("kernels-%s" % job.app)
    teardown(job, ob)
    try:
        # Kernels are built, not tested: `bazel build` of a test target materializes its
        # test kernel, the lib tiers and the deps kernel. Cold: no disk or remote cache.
        build_log = job.out / "logs" / "manifest-build.log"
        build_log.parent.mkdir(parents=True, exist_ok=True)
        build_args = ["build", "--keep_going", "--disk_cache=", "--remote_download_outputs=all", "--action_env=MEASURE_SALT=%s" % salt]
        build = timed_process(bazel_io.bazel_cmd(ob, job.rc, *(build_args + flags + job.targets)), job.app_dir, build_log, None, output_base=ob)
        if build["exit_code"] not in ACCEPTED_EXIT_CODES:
            log_first_error(job, "manifest-build", build_log)
        entries = bazel_io.output_digests(ob, job.rc, job.app_dir, manifest_expr(job.targets), analysis_flags(flags, salt))
        for entry in entries:
            if entry["source"] is not None:
                dst = kernel_dir / entry["path"]
                dst.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(entry["source"], dst)
    finally:
        teardown(job, ob)
    if not entries:
        fail("manifest has no entries")
    lines = [
        "# app=%s" % job.app,
        "# batch base build; outputs of DartTestDeps, DartLibKernel and DartTestKernel; paths normalized",
    ]
    lines += ["%s  %s" % (entry["sha256"], entry["path"]) for entry in entries]
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text("\n".join(lines) + "\n")
    tiers = ["%s\t%s" % (entry["mnemonic"], entry["path"]) for entry in entries]
    out_path.with_name("tiers-%s.tsv" % job.app).write_text("\n".join(tiers) + "\n")
    missing = sum(1 for entry in entries if entry["sha256"] == "MISSING")
    print("manifest: %d entries written, %d MISSING (build exit %s)" % (len(entries), missing, build["exit_code"]))
    return 0


def check_salt_report(target, salts, actions):
    by_outputs = {
        label: {tuple(action["outputs"]): action for action in acts} for label, acts in actions.items()
    }
    first, second = by_outputs["a"], by_outputs["b"]
    rows = []
    ok = bool(first) and set(first) == set(second)
    for outputs in sorted(first):
        a = first[outputs]
        b = second.get(outputs, {})
        row = {
            "outputs": list(outputs),
            "key_a": a.get("key"),
            "key_b": b.get("key"),
            "env_a": a["env"].get("MEASURE_SALT"),
            "env_b": b.get("env", {}).get("MEASURE_SALT"),
        }
        row["ok"] = (
            bool(row["key_a"])
            and bool(row["key_b"])
            and row["key_a"] != row["key_b"]
            and row["env_a"] == salts["a"]
            and row["env_b"] == salts["b"]
        )
        ok = ok and row["ok"]
        rows.append(row)
    return {
        "target": target,
        "salt_a": salts["a"],
        "salt_b": salts["b"],
        "kernel_actions": len(first),
        "pass": ok,
        "rows": rows,
    }


def cmd_check_salt(args):
    salt = args.salt or "check-" + uuid.uuid4().hex[:12]
    job = Job(
        app=args.app,
        os_name=current_os(),
        rules_root=args.rules_root,
        scratch=args.scratch,
        out=Path(args.scratch) / "tool-logs",
        remote_rc=args.remote_rc,
        run_id=salt,
    )
    job.check_wired()
    target = CHECK_TARGET[args.app]
    salts = {"a": salt + "-a", "b": salt + "-b"}
    ob = job.scratch / "ob" / "check-salt"
    actions = {}
    teardown(job, ob)
    try:
        for label, value in salts.items():
            doc = bazel_io.aquery_json(
                ob,
                job.rc,
                job.app_dir,
                'mnemonic("DartTestKernel", deps(%s))' % target,
                ["--action_env=MEASURE_SALT=%s" % value],
            )
            actions[label] = [a for a in bazel_io.parse_actions(doc) if a["mnemonic"] == "DartTestKernel"]
    finally:
        teardown(job, ob)
    report = check_salt_report(target, salts, actions)
    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print("check-salt: %s (%d kernel actions)" % ("pass" if report["pass"] else "FAIL", report["kernel_actions"]))
    return 0 if report["pass"] else 1


def build_parser():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("fetch-apps", help="clone, patch, vendor and wire an app copy")
    p.add_argument("--app", choices=APPS, required=True)
    p.add_argument("--dest", required=True)
    p.add_argument("--flutter-copy", action="store_true", help="skip wiring (the flutter mode uses this)")
    p.set_defaults(func=cmd_fetch_apps)

    p = sub.add_parser("wire", help="copy an app's wiring over its root")
    p.add_argument("--app", choices=APPS, required=True)
    p.add_argument("--dest", required=True)
    p.set_defaults(func=cmd_wire)

    p = sub.add_parser("run", help="run the measurement matrix")
    p.add_argument("--app", choices=APPS, required=True)
    p.add_argument("--os", choices=sorted(WORKER_INSTANCES), required=True)
    p.add_argument("--rules-root", default=str(DEFAULT_RULES_ROOT))
    p.add_argument("--out", required=True)
    p.add_argument("--scratch", required=True)
    p.add_argument("--remote-rc", default=None)
    p.add_argument("--salt", required=True)
    p.add_argument("--repeats", type=int, default=3)
    p.add_argument("--free-preinstalled-sdks", choices=("yes", "no"), default="no")
    p.set_defaults(func=cmd_run)

    p = sub.add_parser("manifest", help="SHA-256 manifest of the batch base build")
    p.add_argument("--app", choices=APPS, required=True)
    p.add_argument("--rules-root", default=str(DEFAULT_RULES_ROOT))
    p.add_argument("--scratch", required=True)
    p.add_argument("--remote-rc", default=None)
    p.add_argument("--salt", default=None)
    p.add_argument("--out", required=True)
    p.set_defaults(func=cmd_manifest)

    p = sub.add_parser("check-salt", help="confirm MEASURE_SALT reaches kernel action keys")
    p.add_argument("--app", choices=APPS, required=True)
    p.add_argument("--rules-root", default=str(DEFAULT_RULES_ROOT))
    p.add_argument("--scratch", required=True)
    p.add_argument("--remote-rc", default=None)
    p.add_argument("--salt", default=None)
    p.add_argument("--out", required=True)
    p.set_defaults(func=cmd_check_salt)
    return parser


def main(argv=None):
    args = build_parser().parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
