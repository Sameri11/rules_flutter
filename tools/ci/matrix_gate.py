#!/usr/bin/env python3
"""Gate checks that read the example matrix of .github/workflows/ci.yml.

`rows` checks that every example recorded in the APK hash tables has a matrix
job. `kernel-digests` checks that every matrix job uploaded its test-kernel
digests and that each example's digests agree across OS.
"""

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

WORKFLOW = ".github/workflows/ci.yml"

GOLDENS = (
    "tools/ci/example_hashes_macos.txt",
    "tools/ci/example_hashes_linux.txt",
)

DIGEST_ARTIFACT_PREFIX = "kernel-digests-"


class GateError(Exception):
    pass


def matrix(workflow):
    """Returns the (oses, examples) name sets of the example job's matrix."""
    examples_block = re.search(r"\n        example:\n(.*?)\n    steps:", workflow, re.S)
    os_block = re.search(r"\n        os:\n((?:          - \S+\n)+)", workflow)
    if not examples_block or not os_block:
        raise GateError("no example matrix in {}".format(WORKFLOW))

    examples = set(re.findall(r"^\s+- name: (\S+)$", examples_block.group(1), re.M))
    oses = set(re.findall(r"- (\S+)", os_block.group(1)))
    if not examples or not oses:
        raise GateError("the example matrix in {} lists no examples or no OS".format(WORKFLOW))

    # Digest artifacts are named kernel-digests-<os>-<example> and split on the
    # last hyphen, so a hyphen in an example name would misattribute them.
    hyphenated = sorted(example for example in examples if "-" in example)
    if hyphenated:
        raise GateError("example names must not contain '-': {}".format(hyphenated))
    return oses, examples


def recorded_examples(golden_text):
    return {
        line.split(" ", 1)[0]
        for line in golden_text.splitlines()
        if line and not line.startswith("#")
    }


def check_rows(examples, golden_texts):
    """Returns failures for hash-table rows that no matrix job builds."""
    by_golden = {golden: recorded_examples(text) for golden, text in golden_texts.items()}

    failures = [
        "{} records {} but no matrix job builds it, so its bytes are unchecked.".format(
            golden, sorted(recorded - examples),
        )
        for golden, recorded in by_golden.items()
        if recorded - examples
    ]

    # Both OS tables must gate the same examples; a table updated alone would
    # silently stop covering the other OS.
    goldens = list(by_golden)
    first = goldens[0]
    for golden in goldens[1:]:
        if by_golden[golden] != by_golden[first]:
            failures.append(
                "{} records {} but {} records {} -- the per-OS tables must cover "
                "the same examples.".format(
                    first, sorted(by_golden[first]), golden, sorted(by_golden[golden]),
                ),
            )
    return failures


def artifact_key(artifact_name):
    """Returns (os, example) for a kernel-digests-<os>-<example> artifact."""
    os_name, example = artifact_name.removeprefix(DIGEST_ARTIFACT_PREFIX).rsplit("-", 1)
    return os_name, example


def read_digests(directory):
    """Returns {(os, example): digest lines} from downloaded digest artifacts."""
    found = {}
    for path in Path(directory).glob("*/{}*.txt".format(DIGEST_ARTIFACT_PREFIX)):
        found[artifact_key(path.parent.name)] = set(path.read_text().splitlines()) - {""}
    return found


def check_kernel_digests(oses, examples, found):
    """Returns failures for missing digests and digests that differ by OS."""
    missing = sorted((o, e) for o in oses for e in examples if (o, e) not in found)
    if missing:
        return ["no kernel digests for {}".format(missing)]

    # Kernels are byte-identical across hosts; only driver.dill differs by host.
    reference_os = sorted(oses)[0]
    failures = []
    for example in sorted(examples):
        reference = found[(reference_os, example)]
        for os_name in sorted(oses):
            got = found[(os_name, example)]
            if got != reference:
                failures.append(
                    "{} kernel digests differ on {}: {} vs {}".format(
                        example, os_name, sorted(got), sorted(reference),
                    ),
                )
    return failures


def _expect_error(label, fn, *args):
    try:
        fn(*args)
    except GateError:
        return
    raise SystemExit("FAIL: selftest accepted {}".format(label))


def _selftest():
    workflow = (
        "jobs:\n"
        "  example:\n"
        "    strategy:\n"
        "      matrix:\n"
        "        os:\n"
        "          - macos-15\n"
        "          - ubuntu-latest\n"
        "        example:\n"
        "          - name: demo_app\n"
        "            directory: examples/demo_app\n"
        "          - name: no_plugins\n"
        "            directory: examples/no_plugins\n"
        "    steps:\n"
    )
    oses, examples = matrix(workflow)
    if (oses, examples) != ({"macos-15", "ubuntu-latest"}, {"demo_app", "no_plugins"}):
        raise SystemExit("FAIL: selftest read the matrix as {} {}".format(oses, examples))

    _expect_error("a workflow without a matrix", matrix, "jobs:\n  lint:\n    steps:\n")
    _expect_error(
        "a hyphenated example name",
        matrix,
        workflow.replace("name: no_plugins", "name: no-plugins"),
    )

    rows = "# header\ndemo_app abc\nno_plugins def\n"
    if check_rows(examples, {"macos": rows, "linux": rows}):
        raise SystemExit("FAIL: selftest rejected hash tables that match the matrix")
    if len(check_rows(examples, {"macos": rows + "orphan 123\n", "linux": rows + "orphan 123\n"})) != 2:
        raise SystemExit("FAIL: selftest accepted a recorded example with no matrix job")
    if len(check_rows(examples, {"macos": rows, "linux": "demo_app abc\n"})) != 1:
        raise SystemExit("FAIL: selftest accepted per-OS tables covering different examples")

    if artifact_key("kernel-digests-macos-15-demo_app") != ("macos-15", "demo_app"):
        raise SystemExit("FAIL: selftest split an artifact name on the wrong hyphen")

    digests = {
        (o, e): {"{} kernel".format(e)} for o in oses for e in examples
    }
    if check_kernel_digests(oses, examples, digests):
        raise SystemExit("FAIL: selftest rejected digests that agree across OS")

    incomplete = dict(digests)
    del incomplete[("ubuntu-latest", "no_plugins")]
    if not check_kernel_digests(oses, examples, incomplete):
        raise SystemExit("FAIL: selftest accepted a matrix job with no digests")

    differing = dict(digests)
    differing[("ubuntu-latest", "demo_app")] = {"other kernel"}
    failures = check_kernel_digests(oses, examples, differing)
    if len(failures) != 1 or "demo_app" not in failures[0]:
        raise SystemExit("FAIL: selftest expected one demo_app mismatch, got {}".format(failures))

    print("OK: matrix gate reads the matrix and detects unclaimed rows and digest drift")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=str(ROOT), help="repository root")
    parser.add_argument(
        "--selftest",
        action="store_true",
        help="check the gate logic without reading the workflow",
    )
    commands = parser.add_subparsers(dest="command")
    commands.add_parser("rows", help="every hash-table row has a matrix job")
    digests = commands.add_parser("kernel-digests", help="kernel digests agree across OS")
    digests.add_argument("directory", help="directory the digest artifacts were downloaded to")
    args = parser.parse_args(argv)

    if args.selftest:
        _selftest()
        return 0
    if not args.command:
        parser.error("a command is required unless --selftest is used")

    root = Path(args.root).resolve()
    try:
        oses, examples = matrix((root / WORKFLOW).read_text())
    except GateError as error:
        print("FAIL: {}".format(error))
        return 1

    if args.command == "rows":
        golden_texts = {golden: (root / golden).read_text() for golden in GOLDENS}
        failures = check_rows(examples, golden_texts)
        ok = "OK: every recorded example has a matrix job: {}".format(
            sorted(recorded_examples(golden_texts[GOLDENS[0]])),
        )
    else:
        failures = check_kernel_digests(oses, examples, read_digests(args.directory))
        ok = "OK: kernel digests agree across {} for {}".format(sorted(oses), sorted(examples))

    if failures:
        for failure in failures:
            print("FAIL: {}".format(failure))
        return 1
    print(ok)
    return 0


if __name__ == "__main__":
    sys.exit(main())
