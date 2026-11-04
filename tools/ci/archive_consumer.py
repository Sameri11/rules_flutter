#!/usr/bin/env python3
"""Prove archive-only consumption of both ruleset modules by a standalone app.

Builds `tests/archive_consumer//:app` in release arm64 with the module's
committed `archive_override` declarations, then with the identical sources
against the local rules source through `--override_module`. The unsigned release
APKs must be byte-identical, the archive build must pass `--lockfile_mode=error`
without changing the committed lock, and a planted wrong archive digest must be
rejected on the checksum from a fresh repository state and a fresh base.

Each scenario's output base is shut down before the next one starts and no base
is shared between the origins, so at most one Bazel server is alive and neither
origin's APK can be the other's cache hit. Logs, both APKs, their entry
inventories and provenance.json land in --evidence.

Local run, from this worktree, with an explicit base parent:

    ANDROID_NDK_HOME=$HOME/Library/Android/sdk/ndk/28.2.13676358 \\
    FLUTTER_ROOT=$HOME/fvm/versions/3.47.3 \\
    python3 tools/ci/archive_consumer.py --bazel /tmp/bazelw \\
        --work-dir /tmp/bazelw-archive --evidence /tmp/archive-evidence
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FIXTURE = ROOT / "tests" / "archive_consumer"

# The proof scope: one immutable commit archive of both modules.
PINNED_REVISION = "42c9011f4f44fff205f122c4583aa39198564aea"
ARCHIVE_URL = (
    "https://api.github.com/repos/Sameri11/rules_flutter/tarball/" + PINNED_REVISION
)
ARCHIVE_SHA256 = "06d5307ebfe9622aaa12173c6486fe5a9edadb25315cff1398947d50996ae691"
STRIP_ROOT = "Sameri11-rules_flutter-42c9011"
# Module name -> its directory in the archive, which is also its repository name.
MODULES = {"sameri11_rules_flutter_core": "rules_flutter_core",
           "sameri11_rules_flutter_android": "rules_flutter_android"}
# Same length as the measured digest: the plant changes content only.
WRONG_SHA256 = "1" + ARCHIVE_SHA256[1:]

EXPECTED_BAZEL_VERSION = "9.2.0"
TARGET = "//:app"
UNSIGNED_APK = "//:app_unsigned.apk"
APK_ABI = "arm64-v8a"
APK_LIBRARIES = ("libflutter.so", "libapp.so")

# Release, one ABI, committed lock. The fixture's .bazelrc selects these too;
# repeating them keeps the evidence independent of later rc edits.
CONFIG_FLAGS = ("-c", "opt", "--android_platforms=@rules_android//:arm64-v8a",
                "--@rules_flutter_core//flutter:mode=release",
                "--lockfile_mode=error",
                "--experimental_convenience_symlinks=ignore")
# Finite local resources, and no worker outliving its build.
RESOURCE_FLAGS = ("--jobs=4", "--local_resources=cpu=4",
                  "--worker_max_instances=2", "--worker_quit_after_build")
STARTUP_FLAGS = ("--host_jvm_args=-XX:ActiveProcessorCount=4",)
# The negative must not be satisfied by anything fetched earlier.
FRESH_FLAGS = ("--repository_cache=", "--repo_contents_cache=", "--disk_cache=")
NETWORK_MARKERS = ("UnrecoverableHttpException", "Could not resolve host",
                   "Temporary failure in name resolution",
                   "Connection timed out", "Connection reset")


class ProofError(RuntimeError):
    """A proof requirement was not met."""


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def tail(text: str, lines: int = 60) -> str:
    return "\n".join(text.strip().splitlines()[-lines:])


def git(*args) -> tuple[int, str]:
    done = subprocess.run(["git", *args], cwd=str(ROOT), text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    return done.returncode, done.stdout.strip()


class Session:
    """Bazel commands in owned output bases, each shut down when its work ends."""

    def __init__(self, binary: str, work: Path, timeout: int, evidence: Path):
        self.binary = binary
        self.work = work
        self.timeout = timeout
        self.log = evidence / "commands.log"
        self.log.write_text("")

    def base(self, scenario: str) -> Path:
        name = "comparison" if scenario in ("archive", "local") else scenario
        return self.work / ("base-" + name)

    def run(self, scenario: str, args, log_path: Path) -> tuple[int, str]:
        argv = [self.binary, "--output_base=" + str(self.base(scenario)),
                *STARTUP_FLAGS, *args]
        began = time.monotonic()
        try:
            done = subprocess.run(argv, cwd=str(FIXTURE), env=os.environ.copy(),
                                  text=True, stdout=subprocess.PIPE,
                                  stderr=subprocess.STDOUT, timeout=self.timeout)
            code, output = done.returncode, done.stdout
        except subprocess.TimeoutExpired as expired:
            code = None
            output = (expired.stdout or b"").decode() if isinstance(
                expired.stdout, bytes) else (expired.stdout or "")
        line = "exit={} {:6.1f}s :: {}".format(
            "timeout" if code is None else code, time.monotonic() - began,
            shlex.join(argv))
        with self.log.open("a") as handle:
            handle.write(line + "\n")
        print(line, flush=True)
        log_path.write_text(output)
        if code is None:
            raise ProofError("command exceeded {}s: {}".format(
                self.timeout, shlex.join(argv)))
        return code, output

    def ok(self, scenario: str, args, evidence: Path, name: str) -> str:
        code, output = self.run(scenario, args, evidence / (name + ".log"))
        if code != 0:
            raise ProofError("{} failed: exit {}\n{}".format(
                shlex.join(args), code, tail(output)))
        return output

    def fresh(self, scenario: str) -> None:
        if self.base(scenario).exists():
            raise ProofError("negative output base is not fresh")

    def close(self, scenario: str, evidence: Path) -> None:
        argv = [self.binary, "--output_base=" + str(self.base(scenario)),
                *STARTUP_FLAGS, "shutdown"]
        try:
            done = subprocess.run(argv, cwd=str(FIXTURE), text=True,
                                  stdout=subprocess.PIPE,
                                  stderr=subprocess.STDOUT, timeout=300)
            line = "{}: exit {}\n{}".format(
                scenario, done.returncode, done.stdout)
        except (OSError, subprocess.TimeoutExpired) as error:
            line = "{}: {}".format(scenario, error)
        with (evidence / "shutdown.log").open("a") as handle:
            handle.write(line + "\n")
        print("shutdown " + line, flush=True)
        if "done" not in locals() or done.returncode != 0:
            raise ProofError("owned Bazel base did not shut down: " + line)


def capture(apk: Path, evidence: Path, label: str) -> dict:
    """Copy the APK, and record the identity both origins must agree on."""
    copied = evidence / (label + ".apk")
    shutil.copyfile(apk, copied)
    with zipfile.ZipFile(copied) as archive:
        infos = archive.infolist()
    inventory = "\n".join(sorted(
        "{:08x} {} {}".format(entry.CRC, entry.file_size, entry.filename)
        for entry in infos)) + "\n"
    (evidence / (label + "-inventory.txt")).write_text(inventory)
    prefix = "lib/{}/".format(APK_ABI)
    libraries = sorted(entry.filename for entry in infos
                       if entry.filename.startswith(prefix)
                       and entry.filename.endswith(".so"))
    missing = [name for name in APK_LIBRARIES if prefix + name not in libraries]
    if missing:
        raise ProofError("{} lacks {}: {}".format(
            label, APK_ABI, ", ".join(missing)))
    return {"apk": copied.name, "sha256": sha256(copied),
            "size": copied.stat().st_size,
            "inventory": label + "-inventory.txt",
            "inventory_sha256": hashlib.sha256(inventory.encode()).hexdigest(),
            "libraries": libraries}


def save(evidence: Path, records: dict) -> None:
    (evidence / "provenance.json").write_text(
        json.dumps(records, indent=2, sort_keys=True) + "\n")


def archive_overrides(text: str) -> list[str]:
    """Return each archive_override call's arguments as one whitespace-joined line."""
    blocks, index = [], 0
    while (start := text.find("archive_override(", index)) != -1:
        depth, cursor = 1, start + len("archive_override(")
        while cursor < len(text) and depth:
            depth += {"(": 1, ")": -1}.get(text[cursor], 0)
            cursor += 1
        if depth:
            raise ProofError("unbalanced archive_override call")
        # Normalize `key = value` to `key=value` so keyword spelling is irrelevant.
        block = " ".join(text[start:cursor].split())
        blocks.append(re.sub(r"\s*=\s*", "=", block))
        index = cursor
    return blocks


def provenance() -> dict:
    """Revision, module identity, environment, and the fixture's own inputs."""
    code, head = git("rev-parse", "HEAD")
    if code != 0:
        raise ProofError("not a Git checkout, so the rules revision is unknown")
    trees = {}
    for directory in MODULES.values():
        for revision in (head, PINNED_REVISION):
            code, tree = git("rev-parse", "{}:{}".format(revision, directory))
            if code != 0:
                raise ProofError("cannot resolve {}:{}; the checkout needs full "
                                 "history".format(revision[:12], directory))
            trees.setdefault(directory, {})[revision] = tree
        if trees[directory][head] != trees[directory][PINNED_REVISION]:
            raise ProofError("{} is not the archived source: {} vs {}".format(
                directory, trees[directory][head],
                trees[directory][PINNED_REVISION]))
    code, dirty = git("status", "--porcelain", "--", *MODULES.values())
    if code != 0 or dirty:
        raise ProofError("the rules modules have local changes: {}".format(
            dirty or "git status failed"))
    lock = FIXTURE / "MODULE.bazel.lock"
    if not lock.exists():
        raise ProofError("no committed lock; generate it with "
                         "--lockfile_mode=update first")
    # The lock must be committed in the delivered fixture; the local proof may
    # run while the fixture is still untracked, so only record that state.
    tracked = git("ls-files", "--error-unmatch",
                  str(lock.relative_to(ROOT)))[0] == 0
    text = (FIXTURE / "MODULE.bazel").read_text()
    for forbidden in ("local_path_override(", "git_override("):
        if forbidden in text:
            raise ProofError("MODULE.bazel may not declare {}".format(
                forbidden.rstrip("(")))
    blocks = archive_overrides(text)
    if len(blocks) != len(MODULES):
        raise ProofError("expected {} archive_override calls, found {}".format(
            len(MODULES), len(blocks)))
    overlays = {}
    for module, directory in MODULES.items():
        declared = [block for block in blocks if module in block]
        if len(declared) != 1:
            raise ProofError("no single archive_override for {}".format(module))
        required = (ARCHIVE_URL, ARCHIVE_SHA256,
                    "{}/{}".format(STRIP_ROOT, directory), 'type="tar.gz"')
        missing = [value for value in required if value not in declared[0]]
        if missing:
            raise ProofError("{} archive_override lacks {}".format(
                module, ", ".join(missing)))
        overlays[module] = "{}/{}".format(STRIP_ROOT, directory)
    return {
        "revision": head,
        "module_trees": {directory: tree[head]
                         for directory, tree in trees.items()},
        "pinned_revision": PINNED_REVISION,
        "modules_clean": True,
        "lock_tracked": tracked,
        "archive_url": ARCHIVE_URL,
        "archive_sha256": ARCHIVE_SHA256,
        "strip_prefixes": overlays,
        "target": TARGET,
        "unsigned_apk": UNSIGNED_APK,
        "config_flags": list(CONFIG_FLAGS),
        "resource_flags": list(RESOURCE_FLAGS),
        "environment": {
            "platform": sys.platform,
            "flutter_root": os.environ.get("FLUTTER_ROOT", ""),
            "android_ndk_home": os.environ.get("ANDROID_NDK_HOME", ""),
            "android_sdk_root": os.environ.get("ANDROID_SDK_ROOT")
            or os.environ.get("ANDROID_HOME", ""),
        },
        "fixture": {"module_sha256": sha256(FIXTURE / "MODULE.bazel"),
                    "lock_sha256": sha256(lock)},
    }


def bazel_version(session: Session, evidence: Path) -> dict:
    """The fixture's .bazelversion, not an environment override, picks 9.2.0."""
    pinned = (FIXTURE / ".bazelversion").read_text().strip()
    if pinned != EXPECTED_BAZEL_VERSION:
        raise ProofError("the fixture pins {} not {}".format(
            pinned, EXPECTED_BAZEL_VERSION))
    if os.environ.get("USE_BAZEL_VERSION", "").strip():
        raise ProofError("USE_BAZEL_VERSION is set, so .bazelversion selection "
                         "cannot be proven")
    code, output = session.run("archive", ["version"],
                               evidence / "bazel-version.log")
    if code != 0:
        raise ProofError("bazel version failed: {}".format(tail(output)))
    labels = [line.split(":", 1)[1].strip() for line in output.splitlines()
              if line.startswith("Build label:")]
    if labels != [EXPECTED_BAZEL_VERSION]:
        raise ProofError(".bazelversion selected {} not {}".format(
            labels, EXPECTED_BAZEL_VERSION))
    return {"bazelversion_file": pinned, "selected": labels[0],
            "selection": ".bazelversion, no USE_BAZEL_VERSION",
            "raw": "bazel-version.log"}


def resolve_apk(session: Session, scenario: str, flags, evidence: Path,
                name: str) -> Path:
    """Return //:app's unsigned APK: the artifact both origins must agree on.

    `//:app` is an android_binary, so its own output listing names several
    files; the unsigned APK is the single recorded one.
    """
    outputs = session.ok(scenario, ["cquery", "--output=files", *flags,
                                    UNSIGNED_APK], evidence,
                         name + "-cquery").split()
    matches = [Path(item) for item in outputs
               if Path(item).name == "app_unsigned.apk"]
    if len(matches) != 1:
        raise ProofError("{} resolved to {} outputs: {}".format(
            UNSIGNED_APK, len(matches), [str(item) for item in matches]))
    root = session.ok(scenario, ["info", "execution_root"], evidence,
                      name + "-execution-root").strip().splitlines()[-1]
    apk = Path(root) / matches[0]
    if not apk.is_file():
        raise ProofError("configured APK is absent: {}".format(apk))
    return apk


def build(session: Session, origin: str, flags, evidence: Path,
          lockfile_mode: str) -> dict:
    """Build //:app from one origin in its own base, then release that base.

    The comparison base is reused after capturing the archive artifact and
    shutting down its server. Cache reuse is permitted: this tests source
    origin, not two-clean-build reproducibility. The local override graph uses
    lock mode off because the committed lock describes the archive graph.
    """
    overrides = ["--override_module={}={}".format(module, ROOT / directory)
                 for module, directory in MODULES.items()
                 ] if origin == "local" else []
    run_flags = [flag for flag in flags
                 if not flag.startswith("--lockfile_mode=")]
    run_flags.append("--lockfile_mode=" + lockfile_mode)
    lock = FIXTURE / "MODULE.bazel.lock"
    before = sha256(lock)
    try:
        session.ok(origin, ["build", *run_flags, *overrides, TARGET], evidence,
                   origin + "-build")
        if sha256(lock) != before:
            raise ProofError("the build changed the committed lock")
        repositories = {}
        for directory in MODULES.values():
            output = session.ok(
                origin, ["mod", "show_repo", "@" + directory,
                         "--lockfile_mode=off", *overrides],
                evidence, "{}-show-repo-{}".format(origin, directory))
            repositories[directory] = {
                "archive_url": ARCHIVE_URL in output,
                "archive_sha256": ARCHIVE_SHA256 in output}
            if repositories[directory]["archive_url"] != (origin == "archive"):
                raise ProofError(
                    "{} resolves {} from the wrong origin: {}".format(
                        origin, directory, repositories[directory]))
        artifact = capture(
            resolve_apk(session, origin, run_flags + overrides, evidence,
                        origin),
            evidence, origin + "-app")
    finally:
        session.close(origin, evidence)
    return {"origin": origin, "flags": run_flags + overrides,
            "lockfile_mode": lockfile_mode,
            "override_flags": overrides,
            "lockfile_sha256_before": before,
            "lockfile_sha256_after": sha256(lock), "lockfile_unchanged": True,
            "repositories": repositories, "artifact": artifact}


def wrong_digest(session: Session, evidence: Path, flags) -> dict:
    """Plant a wrong archive digest, require a checksum failure, then restore."""
    module = FIXTURE / "MODULE.bazel"
    original = module.read_bytes()
    planted = original.decode().replace(ARCHIVE_SHA256, WRONG_SHA256)
    if planted == original.decode():
        raise ProofError("the fixture records no archive digest to plant")
    if planted.replace(WRONG_SHA256, ARCHIVE_SHA256) != original.decode():
        raise ProofError("the plant changed more than the archive digest")
    # The negative is about checksum verification, so lock enforcement cannot be
    # allowed to fail first: the planted MODULE.bazel does not match the lock.
    negative = [flag for flag in flags
                if not flag.startswith("--lockfile_mode=")]
    session.fresh("wrong-digest")
    try:
        module.write_text(planted)
        code, output = session.run(
            "wrong-digest",
            ["build", "--nobuild", *FRESH_FLAGS, "--lockfile_mode=off",
             *negative, TARGET],
            evidence / "wrong-digest.log")
    finally:
        module.write_bytes(original)
        session.close("wrong-digest", evidence)
    restored = sha256(module)
    if restored != hashlib.sha256(original).hexdigest():
        raise ProofError("MODULE.bazel was not restored byte for byte")
    network = [marker for marker in NETWORK_MARKERS if marker in output]
    checksum = "Checksum was" in output and "but wanted" in output
    problems = []
    if code == 0:
        problems.append("the planted digest was accepted")
    if not checksum:
        problems.append("the failure was not a checksum mismatch")
    if WRONG_SHA256 not in output:
        problems.append("the failure does not report the planted digest")
    if ARCHIVE_URL not in output:
        problems.append("the failure does not report the archive URL")
    if network:
        problems.append("network failure: " + ", ".join(network))
    result = {"planted_sha256": WRONG_SHA256, "exit": code,
              "checksum_mismatch": checksum,
              "archive_url_reported": ARCHIVE_URL in output,
              "failed_repositories": sorted(
                  name for name in MODULES if name in output),
              "network_markers": network,
              "fresh_output_base": str(session.base("wrong-digest")),
              "module_restored_sha256": restored, "raw": "wrong-digest.log",
              "problems": problems}
    if problems:
        raise ProofError("wrong-digest rejection: {}\n{}".format(
            "; ".join(problems), tail(output)))
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--work-dir", type=Path,
                        help="owned output-base directory; may reuse a stopped comparison base")
    parser.add_argument("--bazel", default=os.environ.get("BAZEL", "bazel"),
                        help="Bazel client; /tmp/bazelw forwards startup options")
    parser.add_argument("--command-timeout", type=int, default=2700)
    args = parser.parse_args()
    if not Path(args.bazel).exists() and shutil.which(args.bazel) is None:
        sys.exit("FAIL: Bazel client not found: {}".format(args.bazel))
    for name in ("ANDROID_NDK_HOME", "FLUTTER_ROOT"):
        if not os.environ.get(name, "").strip():
            sys.exit("FAIL: {} is unset".format(name))
    evidence = args.evidence.resolve()
    evidence.mkdir(parents=True, exist_ok=True)
    (evidence / "shutdown.log").write_text("")
    records: dict = {"status": "incomplete", "checks": {}}
    work = args.work_dir.resolve() if args.work_dir else Path(
        tempfile.mkdtemp(prefix="archive-consumer-"))
    work.mkdir(parents=True, exist_ok=True)
    session = Session(args.bazel, work, args.command_timeout, evidence)

    flags = [*CONFIG_FLAGS, *RESOURCE_FLAGS,
             "--repo_env=ANDROID_NDK_HOME=" + os.environ["ANDROID_NDK_HOME"],
             "--repo_env=FLUTTER_ROOT=" + os.environ["FLUTTER_ROOT"]]

    try:
        records.update(provenance())
        save(evidence, records)
        records["checks"]["bazel_version"] = bazel_version(session, evidence)
        records["checks"]["archive"] = build(
            session, "archive", flags, evidence, "error")
        records["checks"]["local"] = build(
            session, "local", flags, evidence, "off")
        fields = ("sha256", "size", "inventory_sha256", "libraries")
        archive = records["checks"]["archive"]["artifact"]
        local = records["checks"]["local"]["artifact"]
        differing = [field for field in fields if archive[field] != local[field]]
        records["checks"]["comparison"] = {
            "identical": not differing,
            "equal_fields": [field for field in fields if field not in differing],
            "differing_fields": differing,
            "archive_sha256": archive["sha256"], "local_sha256": local["sha256"],
            "size": archive["size"]}
        save(evidence, records)
        if differing:
            raise ProofError("the archive and local APKs differ in {}".format(
                ", ".join(differing)))
        records["checks"]["wrong_digest"] = wrong_digest(session, evidence, flags)
        save(evidence, records)
    except ProofError as error:
        records["status"] = "failed"
        records["error"] = str(error)
        save(evidence, records)
        print("FAIL: {}".format(error), file=sys.stderr)
        sys.exit(1)
    fixture = records["fixture"]
    fixture["module_sha256_after"] = sha256(FIXTURE / "MODULE.bazel")
    fixture["lock_sha256_after"] = sha256(FIXTURE / "MODULE.bazel.lock")
    fixture["restored"] = (
        fixture["module_sha256"] == fixture["module_sha256_after"]
        and fixture["lock_sha256"] == fixture["lock_sha256_after"])
    records["status"] = "passed" if fixture["restored"] else "failed"
    save(evidence, records)
    if not fixture["restored"]:
        sys.exit("FAIL: planted inputs were not restored")
    print("\nOK: archive-only consumption proved")
    print("  archive APK == local APK: {}".format(
        records["checks"]["comparison"]["archive_sha256"]))
    print("  wrong digest rejected on the checksum; lock unchanged in error mode")
    print("  evidence: {}".format(evidence))


if __name__ == "__main__":
    main()
