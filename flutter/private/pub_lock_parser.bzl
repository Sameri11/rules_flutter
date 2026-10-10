"""A minimal pubspec.lock / pubspec.yaml reader.

Pure Starlark with no Bazel API: the extension and the hub repository rule call
it, and //flutter/private:pub_lock_parser_test exercises it directly.

`pubspec.lock` is written by pub in one fixed shape, so this is a line reader for
that shape, not a YAML parser. Anything outside the shape fails with the line
number instead of being guessed at:

    packages:
      <name>:                       # indent 2
        dependency: "direct main"   # indent 4: scalar fields
        description:                # indent 4: nested map, or a scalar (sdk)
          name: <name>              # indent 6
          sha256: <hex>
          url: "https://pub.dev"
        source: hosted|sdk|path|git
        version: "1.2.3"
    sdks:
      dart: ">=3.0.0 <4.0.0"
"""

visibility(["//flutter"])

_LOWER_HEX = "0123456789abcdef"
_NAME_CHARS = "abcdefghijklmnopqrstuvwxyz0123456789_"
_VERSION_CHARS = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.+-"

def _die(where, message, line):
    fail("{}: {}: {}".format(where, message, repr(line)))

def _scalar(raw, where, line):
    """A YAML scalar as pub writes it: plain, "double" or 'single' quoted."""
    v = raw.strip()
    if v == "":
        return ""
    first = v[0]
    if first == '"':
        if len(v) < 2 or v[-1] != '"':
            _die(where, "unterminated double-quoted scalar", line)
        body = v[1:-1]
        out = []
        skip = False
        for i in range(len(body)):
            if skip:
                skip = False
                continue
            c = body[i]
            if c == "\\":
                if i + 1 >= len(body) or body[i + 1] not in ['"', "\\", "/"]:
                    _die(where, "unsupported escape sequence", line)
                out.append(body[i + 1])
                skip = True
            elif c == '"':
                _die(where, "unescaped quote inside scalar", line)
            else:
                out.append(c)
        return "".join(out)
    if first == "'":
        if len(v) < 2 or v[-1] != "'":
            _die(where, "unterminated single-quoted scalar", line)
        return v[1:-1].replace("''", "'")
    if first in "[{|>&*!%@`":
        _die(where, "unsupported YAML construct", line)
    comment = v.find(" #")
    if comment >= 0:
        v = v[:comment].rstrip()
    return v

def _all_in(text, alphabet):
    for i in range(len(text)):
        if text[i] not in alphabet:
            return False
    return True

def parse_pubspec_lock(text):
    """Reads pub's lockfile shape into `{"packages": {name: fields}, "sdks": {}}`.

    Each package is its scalar fields plus `description`: a dict for the nested
    form (hosted, path, git) or a string for the inline form (sdk).

    Args:
      text: contents of a pubspec.lock.

    Returns:
      The parsed lock.
    """
    packages = {}
    sdks = {}
    section = ""
    package = ""
    in_description = False
    lines = text.split("\n")
    for n in range(len(lines)):
        where = "pubspec.lock:{}".format(n + 1)
        raw = lines[n].rstrip("\r")
        rest = raw.lstrip(" ")
        if rest == "" or rest.startswith("#"):
            continue
        if rest[0] == "\t":
            _die(where, "tab indentation", raw)
        indent = len(raw) - len(rest)
        key, colon, value = rest.partition(":")
        if colon == "" or key == "" or key[0] in "\"'":
            _die(where, "expected an unquoted `key: value` line", raw)

        if indent == 0:
            in_description = False
            package = ""
            if key not in ["packages", "sdks"]:
                _die(where, "unknown top-level key", raw)
            if value.strip() not in ["", "{}"]:
                _die(where, "unsupported inline value for a section", raw)
            section = key
        elif section == "packages" and indent == 2:
            if value.strip() != "":
                _die(where, "package entry must be a bare `name:`", raw)
            if key in packages:
                _die(where, "duplicate package", raw)
            package = key
            packages[package] = {}
            in_description = False
        elif section == "packages" and indent == 4 and package != "":
            fields = packages[package]
            if key in fields:
                _die(where, "duplicate field", raw)
            if key == "description" and value.strip() == "":
                fields["description"] = {}
                in_description = True
            else:
                fields[key] = _scalar(value, where, raw)
                in_description = False
        elif section == "packages" and indent == 6 and in_description:
            description = packages[package]["description"]
            if key in description:
                _die(where, "duplicate description field", raw)
            description[key] = _scalar(value, where, raw)
        elif section == "sdks" and indent == 2:
            sdks[key] = _scalar(value, where, raw)
        else:
            _die(where, "unexpected indentation or structure", raw)
    return {"packages": packages, "sdks": sdks}

def _check_name(name, what):
    if name == "" or not _all_in(name, _NAME_CHARS) or name[0].isdigit():
        fail("pubspec.lock: {} {} is not a valid package name".format(what, repr(name)))

def _check_version(name, version):
    if version == "" or not _all_in(version, _VERSION_CHARS):
        fail("pubspec.lock: package {} has an unusable version {}".format(name, repr(version)))

def resolve_lock(text):
    """Classifies lock entries; fails closed on anything not modelled.

    Returns `{"hosted": [...], "sdk": [...], "path": [...]}`,
    each list sorted by package name. Hosted entries carry the lock's
    sha256 and server URL; nothing here reaches the network. A `git` source
    fails: the lock pins one by commit, not by a content hash Bazel's downloader
    can verify, so it is not modelled yet.

    Args:
      text: contents of a pubspec.lock.

    Returns:
      The classified entries.
    """
    parsed = parse_pubspec_lock(text)
    hosted = []
    sdk = []
    path = []
    for name in sorted(parsed["packages"].keys()):
        package = parsed["packages"][name]
        _check_name(name, "entry")
        source = package.get("source", "")
        version = package.get("version", "")
        description = package.get("description")
        if source == "hosted":
            if type(description) != "dict":
                fail("pubspec.lock: hosted package {} has no description map".format(name))
            if description.get("name") != name:
                fail("pubspec.lock: hosted package {} names {} in its description".format(name, repr(description.get("name"))))
            sha = description.get("sha256", "")
            if len(sha) != 64 or not _all_in(sha, _LOWER_HEX):
                fail("pubspec.lock: hosted package {} has no usable sha256 (got {}); refusing to fetch an unpinned archive".format(name, repr(sha)))
            url = description.get("url", "").rstrip("/")
            if not url.startswith("https://"):
                fail("pubspec.lock: hosted package {} has non-https server {}".format(name, repr(url)))
            _check_version(name, version)
            hosted.append({"name": name, "version": version, "sha256": sha, "url": url})
        elif source == "sdk":
            if description != "flutter":
                fail("pubspec.lock: sdk package {} comes from sdk {} (only flutter is modelled)".format(name, repr(description)))
            sdk.append({"name": name, "version": version})
        elif source == "path":
            if type(description) != "dict" or description.get("relative") != "true":
                fail("pubspec.lock: path package {} must be a relative path dependency".format(name))
            path.append({"name": name, "version": version, "path": description.get("path", "")})
        elif source == "git":
            fail(
                ("pubspec.lock: package {} comes from git ({}); git sources are not supported: " +
                 "the lock records a commit, not a content hash, so the fetch could not be pinned. " +
                 "Depend on a hosted or path package instead.").format(
                    name,
                    repr(description.get("url", "") if type(description) == "dict" else description),
                ),
            )
        else:
            fail("pubspec.lock: package {} has unknown source {}".format(name, repr(source)))
    return {"hosted": hosted, "sdk": sdk, "path": path}

# ---- pubspec.yaml ---------------------------------------------------------------

def pubspec_sdk_constraint(text):
    """`environment.sdk` as written, or "" when absent.

    Handles the block form and the one-line flow form. Anything else under
    `environment:` fails rather than being guessed at.

    Args:
      text: contents of a pubspec.yaml.

    Returns:
      The constraint string.
    """
    lines = text.split("\n")
    for n in range(len(lines)):
        line = lines[n].rstrip("\r")
        if not line.startswith("environment:"):
            continue
        head = line[len("environment:"):].strip()
        if head.startswith("#"):
            head = ""
        if head != "":
            if not (head.startswith("{") and head.endswith("}")):
                _die("pubspec.yaml", "unsupported `environment:` form", line)
            for item in head[1:-1].split(","):
                k, _, v = item.partition(":")
                if k.strip() == "sdk":
                    return _scalar(v, "pubspec.yaml", line)
            return ""
        block_indent = -1
        for m in range(n + 1, len(lines)):
            inner = lines[m].rstrip("\r")
            stripped = inner.lstrip(" ")
            if stripped == "" or stripped.startswith("#"):
                continue
            indent = len(inner) - len(stripped)
            if indent == 0:
                break
            if block_indent < 0:
                block_indent = indent
            if indent != block_indent:
                continue
            k, _, v = stripped.partition(":")
            if k.strip() == "sdk":
                return _scalar(v, "pubspec.yaml", inner)
        return ""
    return ""

def _lower_bound(constraint):
    """[major, minor] of the constraint's lower bound, or None when unbounded."""
    c = constraint.strip()
    for op in [">= ", "> ", "<= ", "< "]:
        c = c.replace(op, op.strip())
    c = c.split("||")[0].strip()
    if c == "" or c == "any" or c[0] == "<":
        return None
    if c[0] == "^":
        v = c[1:]
    elif c.startswith(">="):
        v = c[2:].split(" ")[0]
    elif c[0] == ">":
        v = c[1:].split(" ")[0]
    elif c[0].isdigit():
        v = c.split(" ")[0]
    else:
        fail("pubspec.yaml: unsupported SDK constraint {}".format(repr(constraint)))
    core = v.split("+")[0].split("-")[0]
    parts = core.split(".")
    if len(parts) < 2 or not parts[0].isdigit() or not parts[1].isdigit():
        fail("pubspec.yaml: unsupported SDK constraint {}".format(repr(constraint)))
    return [int(parts[0]), int(parts[1])]

def language_version(pubspec_text):
    """The package's Dart language version as pub records it.

    Lower bound of `environment.sdk`, major.minor; a constraint with no lower
    bound gets pub's default, 2.7.

    Args:
      pubspec_text: contents of a pubspec.yaml.

    Returns:
      The language version as `major.minor`.
    """
    bound = _lower_bound(pubspec_sdk_constraint(pubspec_text))
    if bound == None:
        return "2.7"
    return "{}.{}".format(bound[0], bound[1])

def pubspec_version(pubspec_text):
    """The top-level `version:` of a pubspec.yaml, or "0.0.0" (SDK packages).

    Args:
      pubspec_text: contents of a pubspec.yaml.

    Returns:
      The version string.
    """
    for raw in pubspec_text.split("\n"):
        if raw.startswith("version:"):
            return raw[len("version:"):].split("#")[0].strip().strip("\"'")
    return "0.0.0"

def pubspec_dependencies(pubspec_text, section = "dependencies"):
    """Sorted names in a pubspec's top-level `<section>:` block mapping.

    Only block style is supported (`dependencies: {}` is the empty flow form);
    anything else fails closed.

    Args:
      pubspec_text: contents of a pubspec.yaml.
      section: the top-level key to read.

    Returns:
      The sorted dependency names.
    """
    names = []
    inside = False
    child_indent = -1
    for raw in pubspec_text.split("\n"):
        line = raw.rstrip()
        stripped = line.lstrip(" ")
        if not stripped or stripped.startswith("#"):
            continue
        indent = len(line) - len(stripped)
        if indent == 0:
            inside = False
            if stripped.startswith(section + ":"):
                rest = stripped[len(section) + 1:].split("#")[0].strip()
                if rest == "":
                    inside = True
                    child_indent = -1
                elif rest != "{}":
                    fail("pubspec.yaml: unsupported flow-style `{}` value: {}".format(section, rest))
            continue
        if not inside:
            continue
        if child_indent == -1:
            child_indent = indent
        if indent == child_indent:
            names.append(stripped.split(":")[0].strip().strip("\"'"))
    return sorted(names)

def _yaml_scalar(value):
    value = value.split(" #")[0].strip()
    if len(value) >= 2 and value[0] in "\"'" and value[-1] == value[0]:
        value = value[1:-1]
    return value

def pubspec_flutter_plugin(pubspec_text):
    """`flutter: plugin:` facts of a pubspec.yaml: `(implements, android)`.

    `implements` is `flutter.plugin.implements` -- the app-facing package a
    federated implementation serves -- or "". `android` is the scalar keys of
    `flutter.plugin.platforms.android` (`package`, `pluginClass`,
    `dartPluginClass`, `ffiPlugin`, `default_package`, `dartFileName`), or None
    when there is no such block: what `flutter pub get` reads for the android
    list of `.flutter-plugins-dependencies` and for GeneratedPluginRegistrant.
    Block style and the one-line `{k: v, ...}` flow form are supported.

    Args:
      pubspec_text: contents of a pubspec.yaml.

    Returns:
      `(implements, android)`.
    """
    stack = []  # [(indent, key)]
    found = None
    implements = ""
    for raw in pubspec_text.split("\n"):
        line = raw.rstrip()
        stripped = line.lstrip(" ")
        if not stripped or stripped.startswith("#") or stripped.startswith("- "):
            continue
        indent = len(line) - len(stripped)
        if ":" not in stripped:
            continue
        key, _, value = stripped.partition(":")
        key = _yaml_scalar(key)
        value = value.strip()
        for _ in range(len(stack)):
            if stack and stack[-1][0] >= indent:
                stack.pop()
        path = [s[1] for s in stack]
        if path == ["flutter", "plugin"] and key == "implements" and value != "":
            implements = _yaml_scalar(value)
        elif path == ["flutter", "plugin", "platforms"] and key == "android":
            found = found or {}
            if value.startswith("{"):
                if not value.endswith("}"):
                    fail("pubspec.yaml: unsupported multi-line flow map for android plugin: {}".format(value))
                for pair in value[1:-1].split(","):
                    k, _, v = pair.partition(":")
                    if k.strip():
                        found[_yaml_scalar(k)] = _yaml_scalar(v)
        elif path == ["flutter", "plugin", "platforms", "android"] and value != "":
            found[key] = _yaml_scalar(value)
        if value == "" or value.startswith("#"):
            stack.append((indent, key))
    return implements, found
