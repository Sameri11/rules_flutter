"""Writes the entrypoint of a package's lib tier: one import per library under lib/.

The lib tier compiles every library of the package's `lib/` by `package:` URI,
so one kernel holds them all for the package's tests. Two kinds of file are
left out, both by rule rather than by name:

- part files: any file with a `part of` directive. They are compiled through
  their owning library.
- web-only files: a library that reaches, through unconditional imports and
  exports, a library the VM target does not provide (`dart:html`, `dart:js`,
  `dart:js_interop`, `dart:js_interop_unsafe`, `dart:js_util`, `dart:ui_web`,
  `dart:_js_annotations`, `dart:mirrors`, or `package:web/` and `package:js/`).
  A conditional directive (one with an `if (...)` clause) is not followed, as
  the compiler takes the alternative for the VM. The check covers every
  package in the package config, so a generated registrant that imports a
  `*_web` plugin is web-only too.

Usage: lib_entry.py <package_name_file> <package_config> <package_dir> <entry_out> <lib_list>
<package_dir> is the package's directory, as the execroot path of its pubspec.yaml.
Each line of lib_list is a path, a tab, and the file's path under <package_dir>/lib/. The first path is what open() reads: a generated file's is under bazel-out. Lists the excluded files on stderr.
"""

import argparse
import collections
import os
import re
import sys
from urllib.parse import unquote, urlparse

# Unconditional imports of these reach a library the VM target does not provide.
_WEB_DART_LIBS = frozenset([
    "dart:html",
    "dart:js",
    "dart:js_interop",
    "dart:js_interop_unsafe",
    "dart:js_util",
    "dart:ui_web",
    "dart:_js_annotations",
    "dart:mirrors",
])
_WEB_PACKAGE_PREFIXES = ("package:web/", "package:js/")

# One import, export or part directive. `rest` holds everything after the URI up to
# the semicolon: an `if (...)` clause, `show`, `as`, and so on.
_DIRECTIVE = re.compile(r"""^\s*(import|export|part)\s+(['"])([^'"]+)\2([^;]*);""", re.M | re.S)
_PART_OF = re.compile(r"^\s*part\s+of\s", re.M)


def _is_web_uri(uri):
    return uri in _WEB_DART_LIBS or uri.startswith(_WEB_PACKAGE_PREFIXES)


def _parse(path):
    """Returns (is_part, unconditional_uris) for one Dart file."""
    with open(path, encoding="utf-8", errors="replace") as f:
        text = f.read()
    uris = []
    for m in _DIRECTIVE.finditer(text):
        kind, uri, rest = m.group(1), m.group(3), m.group(4)
        if kind == "part" or re.search(r"\bif\b", rest):
            continue
        uris.append(uri)
    return bool(_PART_OF.search(text)), uris


def _package_dirs(config_path, package_dir):
    """Maps each package name to its lib directory, from the package config."""
    import json

    config_dir = os.path.dirname(config_path)
    with open(config_path, encoding="utf-8") as f:
        config = json.load(f)
    dirs = {}
    for pkg in config["packages"]:
        root = pkg["rootUri"]
        if urlparse(root).scheme == "file":
            root = unquote(urlparse(root).path)
        else:
            root = os.path.join(config_dir, root)
        dirs[pkg["name"]] = os.path.normpath(os.path.join(root, pkg.get("packageUri", "lib/")))
    return dirs


class _Graph:
    def __init__(self, package_dirs):
        self.package_dirs = package_dirs
        self.imports = {}  # file -> existing files it imports unconditionally
        self.web_direct = set()  # files that import a web-only URI unconditionally
        self.part = {}  # file -> is a part file

    def resolve(self, uri, from_file):
        if uri.startswith("dart:"):
            return None
        if uri.startswith("package:"):
            name, _, rel = uri[len("package:"):].partition("/")
            base = self.package_dirs.get(name)
            return os.path.normpath(os.path.join(base, rel)) if base else None
        return os.path.normpath(os.path.join(os.path.dirname(from_file), uri))

    def load(self, path):
        """Parses a file once; returns the existing files it imports unconditionally."""
        if path not in self.imports:
            is_part, uris = _parse(path)
            self.part[path] = is_part
            targets = []
            self.imports[path] = targets
            for uri in uris:
                if _is_web_uri(uri):
                    self.web_direct.add(path)
                    continue
                target = self.resolve(uri, path)
                if target and os.path.isfile(target):
                    targets.append(target)
        return self.imports[path]

    def web_only(self, roots):
        """The set of files that transitively reach a web-only library."""
        pending = collections.deque(roots)
        seen = set(roots)
        while pending:
            for target in self.load(pending.popleft()):
                if target not in seen:
                    seen.add(target)
                    pending.append(target)
        reverse = collections.defaultdict(list)
        for path, targets in self.imports.items():
            for target in targets:
                reverse[target].append(path)
        web = set(self.web_direct)
        frontier = collections.deque(web)
        while frontier:
            for importer in reverse[frontier.popleft()]:
                if importer not in web:
                    web.add(importer)
                    frontier.append(importer)
        return web


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("package_name_file")
    parser.add_argument("package_config")
    parser.add_argument("package_dir")
    parser.add_argument("entry_out")
    parser.add_argument("lib_list", help="a file with a path and a lib-relative path per line, tab-separated")
    args = parser.parse_args(argv)
    with open(args.lib_list, encoding="utf-8") as f:
        lib_entries = [line.rstrip("\n").split("\t", 1) for line in f if line.strip()]

    with open(args.package_name_file, encoding="utf-8") as f:
        package_name = f.read().strip()
    package_dirs = _package_dirs(args.package_config, args.package_dir)
    # The package itself: its lib is the directory of its candidate files, not the config's.
    package_dirs[package_name] = os.path.normpath(os.path.join(args.package_dir, "lib"))

    libs = {}
    for path, rel in lib_entries:
        libs[os.path.normpath(path)] = rel

    graph = _Graph(package_dirs)
    for path in libs:
        graph.load(path)
    part_files = [p for p in libs if graph.part[p]]
    library_files = [p for p in libs if not graph.part[p]]
    web = graph.web_only(library_files)
    entry_files = sorted(libs[p] for p in library_files if p not in web)
    excluded = sorted(libs[p] for p in library_files if p in web)

    lines = ["// Generated by lib_entry.py: the lib tier's entrypoint for package {}.".format(package_name)]
    lines += ["import 'package:{}/{}';".format(package_name, rel) for rel in entry_files]
    lines += ["", "void main() {}", ""]
    with open(args.entry_out, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))

    for rel in sorted(libs[p] for p in part_files):
        print("lib_entry: skipped part file {}".format(rel), file=sys.stderr)
    for rel in excluded:
        print("lib_entry: excluded web-only library {}".format(rel), file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
