#!/usr/bin/env python3
"""Checks the flutter_test launcher against one fixture's expected file.

For each run in <fixture>.expected.json, sets the run's env, runs the launcher,
and checks that:
  * the exit code matches;
  * the JUnit cases match, in order, by name and outcome (pass, fail, skip,
    error), where `load` is the suite-load case. A run whose expected
    `junit` is `absent` must write no JUnit;
  * TEST_PREMATURE_EXIT_FILE is left behind only when the expected
    `premature_exit_file` is `present`;
  * stdout and the JUnit contain no `org-dartlang-root:` URI;
  * a sharded run touched TEST_SHARD_STATUS_FILE.

A run with `sigterm_after_line` is sent SIGTERM once that line appears on
stdout. The launcher must exit within 30 seconds of the signal.

conformance.sh invokes this after clearing the Bazel test variables.

    check.py --launcher <path> --expected <path> --tmp <dir>
"""

import argparse
import json
import os
import signal
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

SIGTERM_EXIT_WAIT = 30
MARKER_WAIT = 120


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


def read(path):
    with open(path) as f:
        return f.read()


def wait_for_line(path, line, proc, deadline):
    """Waits until stdout at [path] has a line equal to [line]. False if the
    process exits first or the deadline passes."""
    while time.monotonic() < deadline:
        if line in read(path).splitlines():
            return True
        if proc.poll() is not None:
            return False
        time.sleep(0.05)
    return False


def check_run(launcher, fixture, run, tmp):
    name = run["name"]
    label = "{}/{}".format(fixture, name)
    xml_path = os.path.join(tmp, "{}_{}.xml".format(fixture, name))
    premature_path = os.path.join(tmp, "{}_{}.premature".format(fixture, name))
    status_path = os.path.join(tmp, "{}_{}.status".format(fixture, name))
    stdout_path = os.path.join(tmp, "{}_{}.stdout".format(fixture, name))
    stderr_path = os.path.join(tmp, "{}_{}.stderr".format(fixture, name))
    for path in (xml_path, xml_path + ".tmp", premature_path):
        if os.path.exists(path):
            os.remove(path)

    env = dict(os.environ)
    env.update(run["env"])
    env["XML_OUTPUT_FILE"] = xml_path
    env["TEST_PREMATURE_EXIT_FILE"] = premature_path
    if "TEST_TOTAL_SHARDS" in run["env"]:
        env["TEST_SHARD_STATUS_FILE"] = status_path

    problems = []
    with open(stdout_path, "w") as out, open(stderr_path, "w") as err:
        proc = subprocess.Popen([launcher], env=env, stdout=out, stderr=err)
        marker = run.get("sigterm_after_line")
        if marker is not None:
            if wait_for_line(stdout_path, marker, proc, time.monotonic() + MARKER_WAIT):
                proc.send_signal(signal.SIGTERM)
            else:
                proc.kill()
                problems.append("never printed {!r}".format(marker))
        try:
            proc.wait(timeout=SIGTERM_EXIT_WAIT if marker is not None else None)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
            problems.append(
                "did not exit within {}s of SIGTERM".format(SIGTERM_EXIT_WAIT)
            )
    stdout_text = read(stdout_path)
    stderr_text = read(stderr_path)

    if proc.returncode != run["exit_code"]:
        problems.append(
            "exit code {}, expected {}".format(proc.returncode, run["exit_code"])
        )

    xml_text = ""
    actual = []
    expect_junit = run.get("junit", "present") == "present"
    if not expect_junit:
        if os.path.exists(xml_path):
            problems.append("JUnit written but expected none")
    elif not os.path.exists(xml_path):
        problems.append("no JUnit written to XML_OUTPUT_FILE")
    else:
        actual = junit_cases(xml_path)
        xml_text = read(xml_path)
        expected = list(run["cases"].items())
        if actual != expected:
            problems.append(
                "cases differ:\n  expected {}\n  actual   {}".format(expected, actual)
            )
    expect_premature = run.get("premature_exit_file", "absent") == "present"
    exists = os.path.exists(premature_path)
    if exists != expect_premature:
        problems.append(
            "premature-exit file {}, expected {}".format(
                "present" if exists else "absent",
                "present" if expect_premature else "absent",
            )
        )

    for name, text in (("stdout", stdout_text), ("junit", xml_text)):
        if "org-dartlang-root:" in text:
            problems.append("{} shows an org-dartlang-root URI".format(name))
    if "TEST_TOTAL_SHARDS" in run["env"] and not os.path.exists(status_path):
        problems.append("TEST_SHARD_STATUS_FILE was not touched")

    expected_count = len(run["cases"]) if expect_junit else 0
    if problems:
        print("FAIL {}".format(label))
        for problem in problems:
            print("  " + problem)
        print("--- stdout ---")
        print(stdout_text)
        print("--- stderr ---")
        print(stderr_text)
        return False
    print("ok {} ({} cases, exit {})".format(label, expected_count, proc.returncode))
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
