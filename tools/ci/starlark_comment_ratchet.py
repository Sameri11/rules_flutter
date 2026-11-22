#!/usr/bin/env python3
"""Prevent new comments in the public Starlark rulesets without rewriting history."""

from collections import Counter
import io
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import tokenize

ROOT = Path(__file__).resolve().parents[2]
RULESETS = ("rules_flutter_core", "rules_flutter_android")
SUFFIXES = (".bzl", ".bazel", ".BUILD", ".star", ".sky")
DIRECTIVES = {"canonical-repository", "function-docstring-args", "print", "unnamed-macro", "unused-variable"}


def in_scope(path):
    parts = path.split("/")
    return len(parts) > 1 and parts[0] in RULESETS and (
        parts[-1] in ("BUILD", "WORKSPACE")
        or parts[-1] == "WORKSPACE.bzlmod"
        or path.endswith(SUFFIXES)
    )


def git(*args, cwd=ROOT):
    result = subprocess.run(["git", *args], cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        raise RuntimeError("git {} failed: {}".format(" ".join(args), result.stderr.decode("utf-8", "replace").strip()))
    return result.stdout


def tracked_paths():
    entries = git("ls-files", "--stage", "-z", "--", *RULESETS).split(b"\0")
    paths = set()
    for entry in entries:
        if not entry:
            continue
        metadata, raw_path = entry.split(b"\t", 1)
        mode = metadata.split()[0]
        path = raw_path.decode("utf-8")
        if in_scope(path):
            if mode == b"120000":
                raise RuntimeError("{}: in-scope symlink is not allowed".format(path))
            paths.add(path)
    return paths


def is_directive(text, standalone):
    if not standalone:
        return False
    match = re.fullmatch(r"# buildifier: disable=([a-z][a-z0-9-]*)", text)
    return bool(match and match.group(1) in DIRECTIVES)


def comments_from_bytes(content, path):
    try:
        text = content.decode("utf-8")
        comments = []
        for token in tokenize.generate_tokens(io.StringIO(text).readline):
            if token.type == tokenize.COMMENT:
                standalone = not token.line[:token.start[1]].strip()
                comments.append((token.start[0], token.string.rstrip(), standalone))
        return comments
    except (UnicodeDecodeError, tokenize.TokenError, IndentationError, SyntaxError, StopIteration) as error:
        raise RuntimeError("{}: cannot tokenize: {}".format(path, error)) from error


def worktree_comments(paths):
    result = {}
    for path in sorted(paths):
        full = ROOT / path
        if full.is_symlink():
            raise RuntimeError("{}: in-scope symlink is not allowed".format(path))
        try:
            content = full.read_bytes()
        except FileNotFoundError:
            continue
        result[path] = comments_from_bytes(content, path)
    return result


def base_comments(ref, paths):
    # Resolve first, then enumerate the tree. A separate ls-tree and show ensures missing paths
    # or malformed tree entries cannot be mistaken for empty files.
    commit = git("rev-parse", "--verify", "--end-of-options", "{}^{{commit}}".format(ref)).decode().strip()
    entries = git("ls-tree", "-r", "-z", commit, "--", *RULESETS).split(b"\0")
    result = {}
    for entry in entries:
        if not entry:
            continue
        meta, raw_path = entry.split(b"\t", 1)
        mode, kind, _oid = meta.split()
        path = raw_path.decode("utf-8")
        if path not in paths:
            continue
        if mode == b"120000" or kind != b"blob":
            raise RuntimeError("{}: in-scope base path is not a regular file".format(path))
        content = git("show", "{}:{}".format(commit, path))
        result[path] = comments_from_bytes(content, path)
    return result


def inventory(paths):
    files = worktree_comments(paths)
    for path, comments in files.items():
        for line, text, standalone in comments:
            mark = " [directive]" if is_directive(text, standalone) else ""
            print("{}:{}: {}{}".format(path, line, text, mark))


def lint(ref):
    paths = tracked_paths()
    current = worktree_comments(paths)
    baseline = base_comments(ref, paths)
    failed = False
    for path in sorted(paths):
        now, before = current.get(path, []), baseline.get(path, [])
        old = Counter(text for _, text, standalone in before if not is_directive(text, standalone))
        for line, text, standalone in now:
            if is_directive(text, standalone):
                continue
            if old[text]:
                old[text] -= 1
            else:
                print("{}:{}: new comment: {}".format(path, line, text))
                failed = True
    return 1 if failed else 0


def selftest():
    script = Path(__file__).resolve()
    with tempfile.TemporaryDirectory(prefix="starlark-comment-ratchet-") as temp:
        root = Path(temp)
        (root / "tools/ci").mkdir(parents=True)
        (root / "tools/ci/starlark_comment_ratchet.py").write_bytes(script.read_bytes())
        (root / "rules_flutter_core").mkdir()
        (root / "rules_flutter_android").mkdir()
        env = dict(os.environ, GIT_CONFIG_NOSYSTEM="1")
        def git_fixture(*args):
            subprocess.run(["git", *args], cwd=root, env=env, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        def lint_fixture(base="HEAD"):
            return subprocess.run([sys.executable, "tools/ci/starlark_comment_ratchet.py", "--base", base], cwd=root, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        file = root / "rules_flutter_core/BUILD"
        file.write_text(
            'x = "# quoted"\n# old\n# duplicate\n# duplicate\n# buildifier: disable=print\n',
            encoding="utf-8",
        )
        git_fixture("init", "-q")
        git_fixture("config", "user.email", "test@example.invalid")
        git_fixture("config", "user.name", "Test")
        git_fixture("add", "rules_flutter_core/BUILD")
        git_fixture("-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "commit", "-qm", "base")
        # Deletion is permitted.
        file.write_text('x = "# quoted"\n# duplicate\n', encoding="utf-8")
        assert lint_fixture().returncode == 0, "deletion rejected"
        file.unlink()
        assert lint_fixture().returncode == 0, "deleted tracked file rejected"
        cases = [
            ('# old\n# new\n', "ordinary addition"),
            ('x = 1 # inline\n', "inline addition"),
            ('# duplicate\n# duplicate\n# duplicate\n', "duplicate addition"),
            ('# rewritten\n', "rewrite"),
            ('# buildifier: disable=print trailing prose\n', "directive prose"),
            ('x = 1 # buildifier: disable=print\n', "inline directive"),
            ('# buildifier: disable=not-allowed\n', "unknown directive"),
        ]
        for content, label in cases:
            file.write_text(content, encoding="utf-8")
            result = lint_fixture()
            assert result.returncode == 1, "{} was accepted: {}".format(label, result.stdout)
        file.write_text(
            'x = "# new quoted hash"\ny = """\n# generated text\n"""\n# old\n# buildifier: disable=unnamed-macro\n',
            encoding="utf-8",
        )
        result = lint_fixture()
        assert result.returncode == 0, "exact known directive rejected: {}".format(result.stdout)
        # New tracked paths are compared against an empty base counterpart.
        extra = root / "rules_flutter_android/new.star"
        extra.write_text("# fresh\n", encoding="utf-8")
        git_fixture("add", "rules_flutter_android/new.star")
        assert lint_fixture().returncode == 1, "new tracked file addition accepted"
        bad = lint_fixture("not-a-real-ref")
        assert bad.returncode != 0, "bad base accepted"
        assert "git" in bad.stderr.lower(), "bad base did not report git failure"
    print("PASS: Starlark comment ratchet selftest")


def main(argv):
    try:
        if argv == ["--selftest"]:
            selftest()
            return 0
        if argv == ["--inventory"]:
            inventory(tracked_paths())
            return 0
        if len(argv) == 2 and argv[0] == "--base":
            return lint(argv[1])
        print("usage: starlark_comment_ratchet.py --base REF | --inventory | --selftest", file=sys.stderr)
        return 2
    except (RuntimeError, OSError) as error:
        print("ERROR: {}".format(error), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
