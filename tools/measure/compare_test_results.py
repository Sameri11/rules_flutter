#!/usr/bin/env python3
"""Compare per-file and grouped JUnit outcomes by source file and test name."""

import argparse
from pathlib import Path
import re
import xml.etree.ElementTree as ET
import json


def source_from_name(name, known_sources):
    normalized = name.replace("\\", "/")
    matches = [source for source in known_sources if normalized.endswith(source)]
    return max(matches, key=len) if matches else None


def outcomes(root, known_sources):
    found = {}
    for xml_path in sorted((root / "testlogs").rglob("test.xml")):
        try:
            tree = ET.parse(xml_path).getroot()
        except (ET.ParseError, OSError):
            continue
        suites = [tree] if tree.tag == "testsuite" else list(tree.iter("testsuite"))
        for suite in suites:
            source = source_from_name(suite.attrib.get("name", ""), known_sources)
            if source is None:
                continue
            for case in suite.findall("testcase"):
                outcome = "pass"
                if case.find("failure") is not None or case.find("error") is not None:
                    outcome = "fail"
                elif case.find("skipped") is not None:
                    outcome = "skip"
                key = (source, case.attrib.get("classname", ""), case.attrib.get("name", ""))
                found[key] = outcome
    return found


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", choices=["serverbox", "oinkoin"], required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    build = Path(__file__).parent / "apps" / args.app / "wiring" / "BUILD.bazel"
    text = build.read_text()
    sources = sorted(set(re.findall(r'src\s*=\s*"(test/[^\"]+_test\.dart)"', text)))
    per_file = outcomes(args.out / "per-file", sources)
    directory = outcomes(args.out / "directory", sources)
    count4 = outcomes(args.out / "count4", sources)

    def compare(grouped):
        keys = sorted(set(per_file) | set(grouped))
        return [{"source": key[0], "classname": key[1], "test": key[2],
                 "per_file": per_file.get(key, "missing"), "grouped": grouped.get(key, "missing")}
                for key in keys if per_file.get(key) != grouped.get(key)]

    report = {"app": args.app, "test_cases": len(per_file),
              "directory_differences": compare(directory), "count4_differences": compare(count4)}
    for policy in ("directory", "count4"):
        entries = report[policy + "_differences"]
        report[policy + "_grouped_only_failures"] = [entry for entry in entries
                                                      if entry["per_file"] == "pass" and entry["grouped"] == "fail"]
    (args.out / "parity.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(json.dumps(report, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
