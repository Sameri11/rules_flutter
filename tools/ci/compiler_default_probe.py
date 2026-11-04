#!/usr/bin/env python3
"""Record the C compiler defaults and the bool-field standard boundary.

Diagnostic only. Compiles one snippet with the default standard, gnu17,
gnu23 and c2x, then writes raw logs and result.json. The assertions cover
the minimal compiler mechanism; they do not prove a package build.
"""

import argparse
import json
import os
import pathlib
import platform
import re
import shutil
import subprocess
import sys

SNIPPET = (
    "typedef int gboolean;\n"
    "struct Change { gboolean bool; };\n"
    "int f(struct Change *p) { return p->bool; }\n"
)

VARIANTS = [
    ("default", []),
    ("gnu17", ["-std=gnu17"]),
    ("gnu23", ["-std=gnu23"]),
    ("c2x", ["-std=c2x"]),
]

COMPILERS = ["cc", "gcc"]

ENV_KEYS = [
    "CC",
    "CXX",
    "CFLAGS",
    "CPPFLAGS",
    "LDFLAGS",
    "CPATH",
    "C_INCLUDE_PATH",
    "GCC_EXEC_PREFIX",
    "COMPILER_PATH",
    "LIBRARY_PATH",
]

ERROR_ON_LINE_2 = re.compile(r"\.c:2:\d+: error")
UNSUPPORTED_STD = re.compile(r"unknown value|unrecognized command-line option|unsupported")


def run(argv):
    proc = subprocess.run(argv, capture_output=True, text=True, check=False)
    return proc.returncode, proc.stdout, proc.stderr


def read_os_release():
    data = {}
    path = pathlib.Path("/etc/os-release")
    if path.exists():
        for line in path.read_text().splitlines():
            if "=" in line and not line.startswith("#"):
                key, value = line.split("=", 1)
                data[key] = value.strip().strip('"')
    return data


def classify(code, stderr, std_flags):
    if code == 0:
        return "accepted"
    if std_flags and UNSUPPORTED_STD.search(stderr) and "std" in stderr:
        return "unsupported_standard"
    if ERROR_ON_LINE_2.search(stderr):
        return "rejected_bool_field"
    return "other_error"


def probe_compiler(name, out_dir, src):
    path = shutil.which(name)
    entry = {"name": name, "path": path, "present": path is not None}
    if path is None:
        return entry

    entry["realpath"] = os.path.realpath(path)
    _, version, _ = run([path, "--version"])
    entry["version_line"] = version.splitlines()[0] if version else ""
    _, full, _ = run([path, "-dumpfullversion"])
    entry["dumpfullversion"] = full.strip()
    _, machine, _ = run([path, "-dumpmachine"])
    entry["dumpmachine"] = machine.strip()

    _, macros, _ = run([path, "-dM", "-E", "-x", "c", os.devnull])
    (out_dir / f"{name}-macros.txt").write_text(macros)
    stdc = re.search(r"^#define __STDC_VERSION__ (\S+)", macros, re.MULTILINE)
    entry["stdc_version_default"] = stdc.group(1) if stdc else None

    _, std_help, _ = run([path, "-Q", "--help=C"])
    std_lines = [line for line in std_help.splitlines() if "-std=" in line]
    (out_dir / f"{name}-std-help.txt").write_text("\n".join(std_lines) + "\n")
    entry["default_std_help"] = std_lines[:3]

    results = {}
    for variant, std_flags in VARIANTS:
        obj = out_dir / f"{name}-{variant}.o"
        code, _, stderr = run([path, *std_flags, "-c", str(src), "-o", str(obj)])
        (out_dir / f"{name}-{variant}.stderr.txt").write_text(stderr)
        results[variant] = {
            "exit": code,
            "classification": classify(code, stderr, std_flags),
            "first_error": next((l for l in stderr.splitlines() if "error" in l), ""),
        }
    entry["variants"] = results
    return entry


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", required=True, type=pathlib.Path)
    parser.add_argument("--runner-label", default="unknown")
    args = parser.parse_args()

    out_dir = args.out
    out_dir.mkdir(parents=True, exist_ok=True)
    src = out_dir / "bool_field.c"
    src.write_text(SNIPPET)

    _, which_cc, _ = run(["which", "-a", "cc"])
    _, which_gcc, _ = run(["which", "-a", "gcc"])
    (out_dir / "which.txt").write_text(which_cc + "--\n" + which_gcc)

    alternatives = None
    if shutil.which("update-alternatives"):
        _, alt_out, alt_err = run(["update-alternatives", "--query", "cc"])
        (out_dir / "update-alternatives-cc.txt").write_text(alt_out + alt_err)
        alternatives = alt_out.splitlines()[:6]

    compilers = {name: probe_compiler(name, out_dir, src) for name in COMPILERS}

    failures = []
    for name in COMPILERS:
        entry = compilers[name]
        if not entry["present"]:
            failures.append(f"{name} missing")
            continue
        variants = entry["variants"]
        if variants["gnu17"]["classification"] != "accepted":
            failures.append(f"{name} gnu17 not accepted: {variants['gnu17']['classification']}")
        c23 = variants["gnu23"]
        if c23["classification"] == "unsupported_standard":
            c23 = variants["c2x"]
            entry["c23_standard_used"] = "c2x"
        else:
            entry["c23_standard_used"] = "gnu23"
        if c23["classification"] != "rejected_bool_field":
            failures.append(f"{name} C23 not rejected at bool field: {c23['classification']}")

    os_release = read_os_release()
    result = {
        "runner_label": args.runner_label,
        "os_release": {
            key: os_release.get(key)
            for key in ("ID", "VERSION_ID", "VERSION_CODENAME", "PRETTY_NAME")
        },
        "image_os": os.environ.get("ImageOS"),
        "image_version": os.environ.get("ImageVersion"),
        "platform": platform.platform(),
        "machine": platform.machine(),
        "python": sys.version.split()[0],
        "env": {key: os.environ[key] for key in ENV_KEYS if key in os.environ},
        "update_alternatives_cc": alternatives,
        "compilers": compilers,
        "assertions_passed": not failures,
        "failures": failures,
    }
    (out_dir / "result.json").write_text(json.dumps(result, indent=2) + "\n")

    print(json.dumps(result, indent=2))
    if failures:
        print("FAILED: " + "; ".join(failures), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
