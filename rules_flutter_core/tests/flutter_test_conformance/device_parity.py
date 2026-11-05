#!/usr/bin/env python3
"""Device-flavor parity for one fixture.

For each run in <fixture>.expected.json, the host launcher and the device
launcher run with the run's environment. The device run gets its name filter,
shard and run id from a run settings file under TMPDIR, the way the device
flavor reads them, and the outer test's filter and shard variables are removed.
The device's stdout is decoded by the device decoder for that run id. Its cases
must equal the host's JUnit cases, in order, by name, outcome and tags, once the
excluded names are removed from both. The exit status must agree unless an
excluded case ran.

With --settings-error, the device run gets a settings file of an unsupported
version. It must report exactly one load error, exit 1, and decode with the same
status.
"""

import argparse
import json
import os
import subprocess
import sys

import check

FILTER_VARS = ("TESTBRIDGE_TEST_ONLY", "TEST_TOTAL_SHARDS", "TEST_SHARD_INDEX")
PREMATURE_VARS = ("TEST_SHARD_STATUS_FILE", "TEST_PREMATURE_EXIT_FILE")


def settings_for(env, run_id):
    """The run settings file that selects what the run's environment selects."""
    settings = {"version": 1, "runId": run_id}
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


def run_host(args, name, run_env, tmp):
    xml = os.path.join(tmp, "host_{}.xml".format(name))
    env = base_env(run_env)
    env["XML_OUTPUT_FILE"] = xml
    proc = subprocess.run([args.host], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return proc.returncode, xml


def run_device(args, name, tmp, fixture, run_env, settings, run_id):
    """Runs the device launcher with [settings] and decodes its stream.

    [run_id] is passed to the decoder when there is one. The device reports a
    settings error under the run id that the settings text names.
    """
    run_dir = os.path.join(tmp, "device_{}".format(name))
    tmpdir = os.path.join(run_dir, "tmp")
    os.makedirs(os.path.join(tmpdir, "rules_flutter_test"), exist_ok=True)
    with open(os.path.join(tmpdir, "rules_flutter_test", "run_settings.json"), "w") as f:
        json.dump(settings, f)
    env = base_env(run_env)
    env["TMPDIR"] = tmpdir
    capture = os.path.join(run_dir, "capture.txt")
    with open(capture, "w") as out:
        proc = subprocess.run([args.device], env=env, stdout=out, stderr=subprocess.STDOUT)
    xml = os.path.join(run_dir, "device.xml")
    decoder_args = [args.dart, args.decoder, "--suite", fixture]
    if run_id is not None:
        decoder_args += ["--run", run_id]
    decoded = subprocess.run(
        decoder_args + ["--xml", xml, capture],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    return proc.returncode, decoded, xml


def report(label, problems, detail):
    if problems:
        print("FAIL {}".format(label))
        for problem in problems:
            print("  " + problem)
        return False
    print("PASS {} ({})".format(label, detail))
    return True


def check_settings_error(args, fixture):
    run_id = "settingserror0"
    device_rc, decoded, device_xml = run_device(
        args, "settings_error", args.tmp, fixture, {},
        {"version": 2, "runId": run_id}, run_id)
    problems = []
    if device_rc != 1:
        problems.append("device exit {} (expected 1)".format(device_rc))
    if decoded.returncode != 1:
        problems.append("decoder exit {} (expected 1): {}".format(
            decoded.returncode, decoded.stderr.strip()))
    cases = []
    if os.path.exists(device_xml):
        cases = [(c["name"], c["outcome"]) for c in check.junit_details(device_xml)]
    if cases != [("load", "error")]:
        problems.append("cases {} (expected [('load', 'error')])".format(cases))
    ok = report("{}/settings_error".format(fixture), problems, "1 load error")
    return ok


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dart", required=True)
    parser.add_argument("--decoder", required=True)
    parser.add_argument("--host", required=True)
    parser.add_argument("--device", required=True)
    parser.add_argument("--expected", required=True)
    parser.add_argument("--tmp", required=True)
    parser.add_argument("--exclude", action="append", default=[])
    parser.add_argument("--settings-error", action="store_true")
    args = parser.parse_args()

    with open(args.expected) as f:
        expected = json.load(f)
    fixture = expected["fixture"]
    if args.settings_error:
        sys.exit(0 if check_settings_error(args, fixture) else 1)

    excluded = set(args.exclude)
    ok = True
    for index, run in enumerate(expected["runs"]):
        label = "{}/{}".format(fixture, run["name"])
        problems = []
        run_id = "parity{}".format(index)

        host_rc, host_xml = run_host(args, run["name"], run["env"], args.tmp)
        host_cases = check.junit_details(host_xml)

        device_rc, decoded, device_xml = run_device(
            args, run["name"], args.tmp, fixture, run["env"],
            settings_for(run["env"], run_id), run_id)
        if decoded.returncode not in (0, 1):
            problems.append("device stream rejected (exit {}): {}".format(
                decoded.returncode, decoded.stderr.strip()))
        else:
            device_cases = check.junit_details(device_xml)
            device_status = decoded.returncode

            host_names = [(c["name"], c["outcome"], c["tags"]) for c in host_cases if c["name"] not in excluded]
            device_names = [(c["name"], c["outcome"], c["tags"]) for c in device_cases if c["name"] not in excluded]
            if host_names != device_names:
                problems.append("cases differ:\n  host   {}\n  device {}".format(host_names, device_names))
            ran_excluded = any(c["name"] in excluded for c in host_cases + device_cases)
            if not ran_excluded and (host_rc != 0) != (device_status != 0):
                problems.append("exit status differs: host {} device {}".format(host_rc, device_status))
            if device_rc != device_status:
                problems.append("device process exit {} disagrees with footer {}".format(device_rc, device_status))

        if not report(label, problems, "{} cases".format(len(host_cases))):
            ok = False
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
