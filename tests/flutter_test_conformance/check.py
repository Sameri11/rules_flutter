#!/usr/bin/env python3
"""Checks the host_test launcher against one fixture's expected file.

For each run in <fixture>.expected.json, sets the run's env, runs the launcher,
and checks that:
  * the exit code matches;
  * the JUnit cases match, in order, by name and outcome (pass, fail, skip,
    error), where `load` is the suite-load case;
  * stdout and the JUnit contain no `org-dartlang-root:` URI;
  * a sharded run touched TEST_SHARD_STATUS_FILE.

conformance.sh invokes this after clearing the Bazel test variables.

    check.py --launcher <path> --expected <path> --tmp <dir>
"""

import argparse
import json
import os
import subprocess
import sys
import xml.etree.ElementTree as ET


def junit_cases(path):
    """Cases in document order as (name, outcome), where outcome is pass,
    fail, skip or error."""
    root = ET.parse(path).getroot()
    cases = []
    for case in root.iter("testcase"):
        children = {child.tag for child in case}
        if "error" in children:
            outcome = "error"
        elif "failure" in children:
            outcome = "fail"
        elif "skipped" in children:
            outcome = "skip"
        else:
            outcome = "pass"
        cases.append((case.get("name"), outcome))
    return cases


def check_run(launcher, fixture, run, tmp):
    env = dict(os.environ)
    env.update(run["env"])
    label = "{}/{}".format(fixture, run["name"])
    xml_path = os.path.join(tmp, "{}_{}.xml".format(fixture, run["name"]))
    env["XML_OUTPUT_FILE"] = xml_path
    status_path = None
    if "TEST_TOTAL_SHARDS" in run["env"]:
        status_path = os.path.join(tmp, "{}_{}.status".format(fixture, run["name"]))
        env["TEST_SHARD_STATUS_FILE"] = status_path

    proc = subprocess.run([launcher], env=env, capture_output=True, text=True)
    problems = []
    if proc.returncode != run["exit_code"]:
        problems.append(
            "exit code {}, expected {}".format(proc.returncode, run["exit_code"])
        )
    if not os.path.exists(xml_path):
        problems.append("no JUnit written to XML_OUTPUT_FILE")
        actual = []
        xml_text = ""
    else:
        actual = junit_cases(xml_path)
        with open(xml_path) as f:
            xml_text = f.read()
    expected = list(run["cases"].items())
    if actual != expected:
        problems.append(
            "cases differ:\n  expected {}\n  actual   {}".format(expected, actual)
        )
    for name, text in (("stdout", proc.stdout), ("junit", xml_text)):
        if "org-dartlang-root:" in text:
            problems.append("{} shows an org-dartlang-root URI".format(name))
    if status_path is not None and not os.path.exists(status_path):
        problems.append("TEST_SHARD_STATUS_FILE was not touched")

    if problems:
        print("FAIL {}".format(label))
        for problem in problems:
            print("  " + problem)
        print("--- stdout ---")
        print(proc.stdout)
        print("--- stderr ---")
        print(proc.stderr)
        return False
    print("ok {} ({} cases, exit {})".format(label, len(expected), proc.returncode))
    return True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--launcher", required=True)
    parser.add_argument("--expected", required=True)
    parser.add_argument("--tmp", required=True)
    args = parser.parse_args()

    with open(args.expected) as f:
        expected = json.load(f)
    ok = True
    for run in expected["runs"]:
        ok = check_run(args.launcher, expected["fixture"], run, args.tmp) and ok
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
