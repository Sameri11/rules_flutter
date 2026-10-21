#!/usr/bin/env python3
"""Summarise the shared-kernels measurement from the downloaded artifacts.

Parity: per app, the main and branch status maps from parity.py are compared target by
target; the failing set is the targets whose status is not PASSED.
Determinism: per app, the branch's manifests from the macOS and Linux digest jobs are
compared per kernel tier (deps, lib, test). A kernel counts as matched when both hosts
built it and the digests are equal.

Layout under --artifacts: parity-<app>-<rules>/ and digest-<os>-<app>/, each holding the
files parity.py and measure.py manifest wrote. Markdown goes to --out and stdout.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import compare_manifests  # noqa: E402

APPS = ("oinkoin", "smooth", "serverbox")
OSES = ("ubuntu-latest", "macos-15")
TIER = {"DartTestDeps": "deps", "DartLibKernel": "lib", "DartTestKernel": "test"}


def read_status(path):
    status = {}
    for line in Path(path).read_text().splitlines():
        if line.strip():
            label, _, value = line.partition("\t")
            status[label] = value
    return status


def parity_section(art, app, out):
    out.append("### Parity: %s" % app)
    maps, runs = {}, {}
    for rules in ("main", "branch"):
        d = art / ("parity-%s-%s" % (app, rules))
        status_file = d / ("status-%s.tsv" % app)
        if not status_file.is_file():
            out.append("- %s: no status file (artifact missing)" % rules)
            return
        maps[rules] = read_status(status_file)
        runs[rules] = json.loads((d / ("run-%s.json" % app)).read_text())
    for rules in ("main", "branch"):
        run = runs[rules]
        counts = ", ".join("%s %d" % (k, v) for k, v in sorted(run["counts"].items()))
        out.append(
            "- %s: %d targets; exit %s; timed out %s; wall %.0f s; %s"
            % (rules, run["targets"], run["exit_code"], run["timed_out"], run["wall_s"], counts)
        )
    failing = {r: sorted(k for k, v in maps[r].items() if v != "PASSED") for r in maps}
    identical_all = maps["main"] == maps["branch"]
    identical_failing = failing["main"] == failing["branch"]
    out.append("- identical per-target status (all targets): %s" % ("yes" if identical_all else "no"))
    out.append("- identical failing set: %s" % ("yes" if identical_failing else "no"))
    for rules in ("main", "branch"):
        out.append("- failing on %s (%d):" % (rules, len(failing[rules])))
        for label in failing[rules]:
            out.append("  - `%s` %s" % (label, maps[rules][label]))
    if not identical_all:
        out.append("- differing targets:")
        for label in sorted(set(maps["main"]) | set(maps["branch"])):
            if maps["main"].get(label) != maps["branch"].get(label):
                out.append("  - `%s`: main %s, branch %s" % (label, maps["main"].get(label), maps["branch"].get(label)))
    out.append("")


def load_side(art, app, os_name):
    # upload-artifact keeps the common ancestor of its paths; the digest
    # files sit under digest/ because the scratch logs share runner.temp.
    d = art / ("digest-%s-%s" % (os_name, app)) / "digest"
    manifest = d / ("manifest-%s.txt" % app)
    tiers = d / ("tiers-%s.tsv" % app)
    if not manifest.is_file() or not tiers.is_file():
        return None
    entries = compare_manifests.load(manifest)
    tier_of = {}
    for line in tiers.read_text().splitlines():
        if line.strip():
            mnemonic, _, path = line.partition("\t")
            tier_of[path] = TIER.get(mnemonic, mnemonic)
    return entries, tier_of


def digest_section(art, app, out):
    out.append("### Determinism: %s (branch kernels, macOS vs Linux)" % app)
    first = load_side(art, app, "ubuntu-latest")
    second = load_side(art, app, "macos-15")
    if first is None or second is None:
        out.append("- artifact missing: ubuntu %s, macos %s" % (first is not None, second is not None))
        out.append("")
        return
    (lin, lin_tier), (mac, mac_tier) = first, second
    tier_of = dict(lin_tier)
    tier_of.update(mac_tier)
    out.append("| tier | kernels (linux) | kernels (macos) | matched | mismatched | MISSING (linux/macos) |")
    out.append("|---|---|---|---|---|---|")
    mismatch_by_tier = {}
    total_mismatch = 0
    for tier in ("deps", "lib", "test"):
        paths = sorted(p for p, t in tier_of.items() if t == tier)
        matched = mismatched = miss_l = miss_m = 0
        for p in paths:
            a, b = lin.get(p), mac.get(p)
            miss_l += a == "MISSING"
            miss_m += b == "MISSING"
            if a is not None and a == b and a != "MISSING":
                matched += 1
            else:
                mismatched += 1
                mismatch_by_tier.setdefault(tier, []).append((p, a, b))
        total_mismatch += mismatched
        out.append(
            "| %s | %d | %d | %d | %d | %d / %d |"
            % (tier, sum(1 for p in paths if p in lin), sum(1 for p in paths if p in mac), matched, mismatched, miss_l, miss_m)
        )
    out.append("")
    out.append("- verdict: %s" % ("identical" if total_mismatch == 0 else "%d kernels differ or are missing on one host" % total_mismatch))
    for tier in ("deps", "lib", "test"):
        for p, a, b in mismatch_by_tier.get(tier, []):
            out.append("  - %s `%s`: linux %s, macos %s" % (tier, p, (a or "absent")[:12], (b or "absent")[:12]))
    out.append("")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--artifacts", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--run-url", default="")
    args = parser.parse_args(argv)
    art = Path(args.artifacts).resolve()
    out = ["# Shared-kernels measurement", ""]
    if args.run_url:
        out += ["Run: %s" % args.run_url, ""]
    out += ["## Parity (ubuntu-latest, main a7bda2f vs branch 3dec6c4)", ""]
    for app in APPS:
        parity_section(art, app, out)
    out += ["## Determinism (branch 3dec6c4)", ""]
    for app in APPS:
        digest_section(art, app, out)
    text = "\n".join(out) + "\n"
    Path(args.out).write_text(text)
    print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
