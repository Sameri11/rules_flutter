#!/usr/bin/env python3
"""Device-flavor parity for one fixture.

For each run in <fixture>.expected.json, the host launcher and the device
launcher run with the run's environment. The device run gets its name filter and
shard from a run settings file under TMPDIR, the way the device flavor reads
them, and the outer test's filter and shard variables are removed. The device's
stdout is decoded by the device decoder. Its cases must equal the host's JUnit
cases, in order, by name and outcome, once the excluded names are removed from
both. The exit status must agree unless an excluded case ran.
"""

import argparse
import json
import os
import subprocess
import sys

import check

FILTER_VARS = ("TESTBRIDGE_TEST_ONLY", "TEST_TOTAL_SHARDS", "TEST_SHARD_INDEX")
PREMATURE_VARS = ("TEST_SHARD_STATUS_FILE", "TEST_PREMATURE_EXIT_FILE")


def settings_for(env):
    """The run settings file that selects what the run's environment selects."""
    settings = {"version": 1}
    if "TESTBRIDGE_TEST_ONLY" in env:
        settings["nameFilter"] = env["TESTBRIDGE_TEST_ONLY"]
    if "TEST_TOTAL_SHARDS" in env:
        settings["shardIndex"] = int(env["TEST_SHARD_INDEX"])
        settings["shardCount"] = int(env["TEST_TOTAL_SHARDS"])
    return settings


def base_env(run_env):
    env = dict(os.environ)
    for var in FILTER_VARS + PREMATURE_VARS:
        env.pop(var, None)
    env.update(run_env)
    return env


def run_host(args, run, tmp):
    xml = os.path.join(tmp, "host_{}.xml".format(run["name"]))
    env = base_env(run["env"])
    env["XML_OUTPUT_FILE"] = xml
    proc = subprocess.run([args.host], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return proc.returncode, xml


def run_device(args, run, tmp, fixture):
    run_dir = os.path.join(tmp, "device_{}".format(run["name"]))
    tmpdir = os.path.join(run_dir, "tmp")
    os.makedirs(os.path.join(tmpdir, "rules_flutter_test"), exist_ok=True)
    with open(os.path.join(tmpdir, "rules_flutter_test", "run_settings.json"), "w") as f:
        json.dump(settings_for(run["env"]), f)
    env = base_env(run["env"])
    env["TMPDIR"] = tmpdir
    capture = os.path.join(run_dir, "capture.txt")
    with open(capture, "w") as out:
        proc = subprocess.run([args.device], env=env, stdout=out, stderr=subprocess.STDOUT)
    xml = os.path.join(run_dir, "device.xml")
    decoded = subprocess.run(
        [args.dart, args.decoder, "--suite", fixture, "--xml", xml, capture],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    return proc.returncode, decoded, xml


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dart", required=True)
    parser.add_argument("--decoder", required=True)
    parser.add_argument("--host", required=True)
    parser.add_argument("--device", required=True)
    parser.add_argument("--expected", required=True)
    parser.add_argument("--tmp", required=True)
    parser.add_argument("--exclude", action="append", default=[])
    args = parser.parse_args()

    with open(args.expected) as f:
        expected = json.load(f)
    fixture = expected["fixture"]
    excluded = set(args.exclude)
    ok = True
    for run in expected["runs"]:
        label = "{}/{}".format(fixture, run["name"])
        problems = []

        host_rc, host_xml = run_host(args, run, args.tmp)
        host_cases = check.junit_details(host_xml)

        device_rc, decoded, device_xml = run_device(args, run, args.tmp, fixture)
        if decoded.returncode not in (0, 1):
            problems.append("device stream rejected (exit {}): {}".format(
                decoded.returncode, decoded.stderr.strip()))
        else:
            device_cases = check.junit_details(device_xml)
            device_status = decoded.returncode

            host_names = [(c["name"], c["outcome"]) for c in host_cases if c["name"] not in excluded]
            device_names = [(c["name"], c["outcome"]) for c in device_cases if c["name"] not in excluded]
            if host_names != device_names:
                problems.append("cases differ:\n  host   {}\n  device {}".format(host_names, device_names))
            ran_excluded = any(c["name"] in excluded for c in host_cases + device_cases)
            if not ran_excluded and (host_rc != 0) != (device_status != 0):
                problems.append("exit status differs: host {} device {}".format(host_rc, device_status))
            if device_rc != device_status:
                problems.append("device process exit {} disagrees with footer {}".format(device_rc, device_status))

        if problems:
            ok = False
            print("FAIL {}".format(label))
            for problem in problems:
                print("  " + problem)
        else:
            print("PASS {} ({} cases)".format(label, len(host_cases)))
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
