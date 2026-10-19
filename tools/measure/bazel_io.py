"""Bazel client helpers for the measurement harness.

Output formats relied on here (UNVERIFIED against a live run of this rules tree):
- `bazel aquery --output=jsonproto` prints {"actions", "artifacts", "pathFragments"}.
  Actions carry `mnemonic`, `targetLabel`, `outputIds`, `environmentVariables`
  (key/value pairs) and `actionKey`. Artifacts map `id` to `pathFragmentId`, and
  path fragments form a parent chain through `parentId` (0 is the root).
  snake_case spellings are accepted as well.
- `bazel info execution_root` and `bazel info repository_cache` print one path.
- `bazel query --output=label` prints one label per line.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
from pathlib import Path

CONFIG_SEGMENT_RE = re.compile(r"^bazel-out/[^/]+/")
MAX_PATH_DEPTH = 64


class BazelError(RuntimeError):
    """A Bazel client call failed or printed output the harness cannot use."""


def bazel_cmd(output_base, rc, *args):
    """Build a bazel command line. Startup options must precede the command."""
    cmd = ["bazel", "--output_base=%s" % output_base]
    if rc:
        cmd.append("--bazelrc=%s" % rc)
    cmd.extend(args)
    return cmd


def run_capture(cmd, cwd):
    proc = subprocess.run(
        cmd,
        cwd=str(cwd),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        universal_newlines=True,
        check=False,
    )
    if proc.returncode != 0:
        lines = proc.stderr.strip().splitlines()
        errors = [line for line in lines if line.startswith("ERROR:")][:3]
        tail = lines[-3:]
        raise BazelError(
            "%s exited %d: %s | %s" % (" ".join(cmd[-2:]), proc.returncode, " | ".join(errors), " | ".join(tail))
        )
    return proc.stdout


def shutdown(output_base, rc, cwd):
    subprocess.run(
        bazel_cmd(output_base, rc, "shutdown"),
        cwd=str(cwd),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )


def clone_tree(src, dst):
    """Copy a tree as copy-on-write clones (APFS on macOS, reflink on Linux) so a snapshot costs no extra disk."""
    if sys.platform == "darwin":
        cmd = ["cp", "-cR", str(src), str(dst)]
    else:
        cmd = ["cp", "-a", "--reflink=auto", str(src), str(dst)]
    Path(dst).parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(cmd, check=True)


def remove_tree(path):
    """Delete a tree. Bazel makes output directories read-only, so restore owner access first."""
    path = Path(path)
    if path.is_symlink() or path.is_file():
        path.unlink()
        return
    if not path.is_dir():
        return
    for root, _dirs, _files in os.walk(path):
        if not os.path.islink(root):
            os.chmod(root, stat.S_IRWXU)
    shutil.rmtree(path)


def query_test_targets(output_base, rc, cwd):
    """`tests(//...)` as sorted labels. Analysis only; nothing is built."""
    out = run_capture(bazel_cmd(output_base, rc, "query", "--output=label", "tests(//...)"), cwd)
    return sorted({line.strip() for line in out.splitlines() if line.strip()})


def info(output_base, rc, cwd, key):
    return run_capture(bazel_cmd(output_base, rc, "info", key), cwd).strip()


def aquery_json(output_base, rc, cwd, expression, analysis_flags):
    out = run_capture(
        bazel_cmd(output_base, rc, "aquery", "--output=jsonproto", *analysis_flags, expression),
        cwd,
    )
    try:
        return json.loads(out)
    except ValueError as err:
        raise BazelError("aquery printed no JSON: %s" % err) from err


def _field(obj, *names, default=None):
    for name in names:
        if name in obj:
            return obj[name]
    return default


def parse_actions(doc):
    """Flatten an aquery jsonproto document into actions with exec-relative output paths."""
    fragments = {}
    for frag in _field(doc, "pathFragments", "path_fragments", default=[]):
        fragments[frag["id"]] = (frag.get("label", ""), _field(frag, "parentId", "parent_id", default=0))
    artifacts = {}
    for art in _field(doc, "artifacts", default=[]):
        artifacts[art["id"]] = _field(art, "pathFragmentId", "path_fragment_id", default=0)

    def exec_path(artifact_id):
        frag_id = artifacts[artifact_id]
        parts = []
        hops = 0
        while frag_id:
            hops += 1
            if hops > MAX_PATH_DEPTH:
                raise BazelError("path fragment chain is too deep")
            label, parent = fragments[frag_id]
            parts.append(label)
            frag_id = parent
        return "/".join(reversed(parts))

    actions = []
    for act in _field(doc, "actions", default=[]):
        outputs = [exec_path(i) for i in _field(act, "outputIds", "output_ids", default=[])]
        env = {}
        for item in _field(act, "environmentVariables", "environment_variables", default=[]):
            env[item.get("key", "")] = item.get("value", "")
        actions.append(
            {
                "mnemonic": act.get("mnemonic", ""),
                "label": _field(act, "targetLabel", "target_label", default=""),
                "outputs": outputs,
                "key": _field(act, "actionKey", "action_key"),
                "env": env,
            }
        )
    return actions


def file_sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def output_digests(output_base, rc, cwd, expression, analysis_flags):
    """SHA-256 of every output of the actions matched by `expression`.

    Paths are normalized by replacing the configuration segment, so the same
    action has the same path on macOS and Linux. The output files must already
    exist; the caller builds them with --remote_download_outputs=all.
    """
    doc = aquery_json(output_base, rc, cwd, expression, analysis_flags)
    root = Path(info(output_base, rc, cwd, "execution_root"))
    found = {}
    for action in parse_actions(doc):
        for exec_path in action["outputs"]:
            path = CONFIG_SEGMENT_RE.sub("bazel-out/CFG/", exec_path)
            source = root / exec_path
            if not source.is_file():
                raise BazelError("output is not on disk: %s" % path)
            entry = {
                "mnemonic": action["mnemonic"],
                "path": path,
                "sha256": file_sha256(source),
            }
            if path in found and found[path] != entry:
                raise BazelError("two actions produce %s differently" % path)
            found[path] = entry
    return [found[path] for path in sorted(found)]


def entries_digest(entries):
    digest = hashlib.sha256()
    for entry in entries:
        digest.update(("%s  %s\n" % (entry["sha256"], entry["path"])).encode("utf-8"))
    return digest.hexdigest()
