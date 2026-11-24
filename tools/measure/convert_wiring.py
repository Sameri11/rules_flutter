#!/usr/bin/env python3
"""Port generated per-file app tests to the current flutter_test API."""

from pathlib import Path
import re
import sys


def calls(text, macro):
    pattern = re.compile(r"(?m)^" + re.escape(macro) + r"\(")
    for match in reversed(list(pattern.finditer(text))):
        start = match.start()
        pos = match.end()
        depth = 1
        quote = None
        escaped = False
        while pos < len(text) and depth:
            ch = text[pos]
            if quote:
                if escaped:
                    escaped = False
                elif ch == "\\":
                    escaped = True
                elif ch == quote:
                    quote = None
            elif ch in "'\"":
                quote = ch
            elif ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
            pos += 1
        if depth:
            raise ValueError("unclosed %s invocation" % macro)
        yield start, pos, text[start:pos]


def main(build_path, flutter_version):
    path = Path(build_path)
    text = path.read_text()
    text = text.replace(
        'load("@rules_flutter//flutter:defs.bzl", "flutter_app", "flutter_test")',
        'load("@rules_flutter//flutter:defs.bzl", "flutter_package", "flutter_pubspec", "flutter_test")',
    )
    text = text.replace(
        "flutter_app(\n",
        'flutter_pubspec(name = "pubspec")\n\nflutter_package(\n    name = "app",\n    pubspec = ":pubspec",\n',
        1,
    )
    text = text.replace('    abis = ["arm64-v8a"],\n', "", 1)
    found = 0
    for start, end, call in calls(text, "flutter_test"):
        call, n = re.subn(r"(?m)^(\s*)app\s*=", r"\1package =", call, count=1)
        if n:
            found += 1
            text = text[:start] + call + text[end:]
    if not found:
        raise SystemExit("no historical flutter_test(app=...) calls in %s" % path)
    suite_calls = list(calls(text, "test_suite"))
    for start, end, call in suite_calls:
        if 'name = "flutter_tests"' not in call:
            continue
        call, count = re.subn(
            r"(tests\s*=\s*\[)(.*)(\])",
            r'\1\2, ":runner_floor_test"\3',
            call,
            count=1,
        )
        if count != 1:
            raise SystemExit("failed to add runner floor to flutter_tests suite in %s" % path)
        text = text[:start] + call + text[end:]
        break
    else:
        raise SystemExit("no flutter_tests test_suite in %s" % path)
    text += """

flutter_test(
    name = "runner_floor_test",
    package = ":app",
    src = "test/runner_floor_test.dart",
)
"""
    path.write_text(text)
    test_dir = path.parent / "test"
    test_dir.mkdir(parents=True, exist_ok=True)
    (test_dir / "runner_floor_test.dart").write_text(
        "import 'package:flutter_test/flutter_test.dart';\n\n"
        "void main() {\n"
        "  test('empty', () {});\n"
        "}\n"
    )
    android_build = path.parent / "android" / "app" / "BUILD.bazel"
    if android_build.is_file():
        if path.parent.name == "serverbox":
            android_build.write_text(
                'package(default_visibility = ["//visibility:public"])\n\n'
                'filegroup(\n'
                '    name = "host_test_data",\n'
                '    srcs = glob(["src/main/AndroidManifest.xml", "src/main/res/xml/*.xml", "src/main/kotlin/**/*.kt"], allow_empty = True),\n'
                ')\n'
            )
        else:
            android_build.write_text('package(default_visibility = ["//visibility:public"])\n')
    module = path.parent / "MODULE.bazel"
    module_text = module.read_text()
    module_text = module_text.replace(
        'bazel_dep(name = "sameri11_rules_flutter", version = "0.1.0", repo_name = "rules_flutter")',
        'bazel_dep(name = "sameri11_rules_flutter_core", version = "0.1.0", repo_name = "rules_flutter")',
    )
    module_text = module_text.replace(
        'module_name = "sameri11_rules_flutter",\n    path = "../..",',
        'module_name = "sameri11_rules_flutter_core",\n    path = "../../rules_flutter_core",',
    )
    module_text = module_text.replace('include("//android:config.MODULE.bazel")', '')
    module_text = module_text.replace(
        'flutter.sdk(version = "3.47.3")',
        'flutter.sdk(version = "%s")' % flutter_version,
    )
    module.write_text(module_text)
    (path.parent / ".bazelversion").write_text("9.2.0\n")
    print("converted %d per-file flutter_test declarations in %s" % (found, path))


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
