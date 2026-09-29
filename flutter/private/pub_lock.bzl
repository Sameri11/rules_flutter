"""pubspec.lock -> Bazel repositories: hosted packages, SDK packages, package configs.

The `pub` module extension reads a consumer's `pubspec.lock` and creates

  * one repository per hosted package, downloaded through Bazel's downloader from
    `<server>/api/archives/<name>-<version>.tar.gz` and pinned to the sha256 the
    lock already records; and
  * one hub repository per lock. Its files, all free of absolute paths:
      - `package_config.json`, rootUris relative to the hub directory. Kernel
        actions run in the execroot and load it as
        `org-dartlang-root:///external/<hub>/package_config.json`.
      - `project_package_config.json`, rootUris relative to `<project>/.dart_tool/`.
        `flutter build bundle` only reads `.dart_tool/package_config.json`, so the
        bundle action copies this one there inside its stage.
      - `package_graph.json`, the other file `flutter build bundle` reads there.
      - `plugins_metadata.json`, the Android plugin list `plugins.project` reads.
      - filegroups `:lib` (every hosted package's packageUri tree and pubspec) and
        `:all` (every hosted package file, for the bundle).

Nothing under ~/.pub-cache appears in any of it, and no rule reads
`flutter pub get`'s outputs (`.dart_tool/`, `.flutter-plugins-dependencies`):
hosted packages are sibling external repositories, SDK packages are directory
symlinks inside `@flutter_sdk` (repo.bzl), and the project and its path packages
are workspace directories. `flutter pub get` remains how a user updates
`pubspec.lock`; Bazel does not resolve versions.

`git` sources are refused (pub_lock_parser.bzl): the lock pins them by commit, and
Bazel cannot verify a content hash for them.
"""

load(":pub_lock_parser.bzl", "language_version", "pubspec_android_plugin", "pubspec_dependencies", "pubspec_version", "resolve_lock")
load(":sdk_packages.bzl", "sdk_package_root")

visibility(["//flutter"])

# `lib` is the packageUri tree plus metadata: what a compile reads. `all` adds
# everything else (assets, LICENSE files) that `flutter build bundle` reads.
# glob() copes with the two hosted files that have spaces in their names.
_PACKAGE_BUILD = """package(default_visibility = ["//visibility:public"])

exports_files(["pubspec.yaml"])

filegroup(
    name = "lib",
    srcs = glob(["lib/**"], allow_empty = True) + ["pubspec.yaml"],
)

filegroup(
    name = "all",
    srcs = glob(["**"], exclude = [".git/**", "BUILD.bazel", "REPO.bazel", "MODULE.bazel", "WORKSPACE"]),
)
"""

def _pub_archive_impl(rctx):
    # Not http_archive: a few published archives (hive_flutter-1.1.0) carry zero padding
    # after the gzip stream, which Bazel's Java extractor rejects ("Garbage after a valid
    # .gz stream"). The download stays downloader-mediated and sha256-pinned; only the
    # unpack is ours.
    #
    # `gzip -dc | tar -x` rather than `tar -xzf`: GNU tar fails such an archive
    # ("Child returned status 2", gzip's trailing-garbage warning), BSD tar does not.
    # The pipeline's status is tar's, so the warning is ignored and a corrupt stream
    # still fails in tar. The sha256 has been verified by then either way.
    rctx.download(url = rctx.attr.urls, output = "_pub_archive.tar.gz", sha256 = rctx.attr.sha256)
    result = rctx.execute(["sh", "-c", 'gzip -dc "$1" | tar -xf -', "sh", "_pub_archive.tar.gz"])
    if result.return_code:
        fail("pub archive {}: unpacking failed: {}".format(rctx.attr.name, result.stderr))
    rctx.delete("_pub_archive.tar.gz")
    rctx.file("BUILD.bazel", rctx.attr.build_file_content)

_pub_archive = repository_rule(
    implementation = _pub_archive_impl,
    doc = "A sha256-pinned hosted pub package archive, unpacked into the repository root.",
    attrs = {
        "urls": attr.string_list(mandatory = True),
        "sha256": attr.string(mandatory = True),
        "build_file_content": attr.string(mandatory = True),
    },
)

def _relpath(base, target):
    """`target` relative to directory `base`, both lists of path segments."""
    common = 0
    for i in range(min(len(base), len(target))):
        if base[i] != target[i]:
            break
        common += 1
    return "/".join([".."] * (len(base) - common) + target[common:])

def _segments(path):
    return [s for s in str(path).split("/") if s]

def _pub_hub_impl(rctx):
    lock_label = rctx.attr.lock
    if not rctx.path(rctx.attr.pubspec).exists:
        fail("pub hub {}: pubspec.yaml must sit beside {} (expected {})".format(rctx.attr.name, lock_label, rctx.attr.pubspec))

    lock = resolve_lock(rctx.read(rctx.attr.lock))
    project_dir = rctx.path(rctx.attr.lock).dirname

    hub_dir = rctx.path(".")
    external = _segments(hub_dir.dirname)

    # Every location below is an execroot-relative segment list. The execroot
    # sees the main repository at its root and any other repository under
    # `external/`, which is where the lock's directory sits in each case.
    workspace_root = rctx.workspace_root
    if lock_label.repo_name:
        workspace_root = hub_dir.dirname.dirname
    project = _segments(str(project_dir))[len(_segments(str(workspace_root))):]

    # Both config locations, as execroot-relative segment lists.
    hub_base = ["external", hub_dir.basename]
    project_base = project + [".dart_tool"]

    # name -> {"dir": execroot-relative segments, "language": "3.4", "pubspec": text}
    entries = {}

    for label, name in rctx.attr.hosted.items():
        text = rctx.read(label)
        entries[name] = {
            "dir": ["external"] + _segments(rctx.path(label).dirname)[len(external):],
            "language": language_version(text),
            "pubspec": text,
        }

    for name in rctx.attr.sdk:
        # Convention, not a table: see sdk_packages.bzl. @flutter_sdk exposes every
        # package it finds, so a package it lacks is a lock/SDK mismatch.
        pubspec = rctx.path(Label("@flutter_sdk//:{}/pubspec.yaml".format(sdk_package_root(name))))
        if not pubspec.exists:
            fail(("pub hub {}: pubspec.lock names SDK package `{}`, but the Flutter SDK " +
                  "has no {}/pubspec.yaml. Run `flutter pub get` with the SDK this build uses.").format(
                rctx.attr.name,
                name,
                sdk_package_root(name),
            ))
        text = rctx.read(pubspec)
        entries[name] = {
            "dir": ["external"] + _segments(pubspec.dirname)[len(external):],
            "language": language_version(text),
            "pubspec": text,
        }

    for package in lock["path"]:
        # `../app_store/x` relative to the project dir, normalized to a workspace-relative
        # segment list (a `..` above the workspace root would leave the checkout: refuse).
        dirsegs = list(project)
        for seg in package["path"].split("/"):
            if seg in ["", "."]:
                continue
            if seg == "..":
                if not dirsegs:
                    fail("pub hub {}: path package {} escapes the workspace: {}".format(rctx.attr.name, package["name"], package["path"]))
                dirsegs.pop()
            else:
                dirsegs.append(seg)
        pubspec = workspace_root.get_child(*(dirsegs + ["pubspec.yaml"]))

        # Not a label (a path package may have no BUILD file): watched by path.
        rctx.watch(pubspec)
        text = rctx.read(pubspec)
        entries[package["name"]] = {
            "dir": dirsegs,
            "language": language_version(text),
            "pubspec": text,
        }

    root_pubspec = rctx.read(rctx.attr.pubspec)
    root_name = _root_package_name(root_pubspec)
    entries[root_name] = {"dir": project, "language": language_version(root_pubspec), "pubspec": root_pubspec}

    expected = len(lock["hosted"]) + len(lock["sdk"]) + len(lock["path"])
    if len(entries) != expected + 1:
        fail("pub hub {}: {} package configs built for {} lock entries plus the root".format(rctx.attr.name, len(entries), expected))

    for filename, base in [
        ("package_config.json", hub_base),
        ("project_package_config.json", project_base),
    ]:
        packages = []
        for name in sorted(entries.keys()):
            entry = entries[name]
            root = _relpath(base, entry["dir"])
            packages.append({
                "name": name,
                "rootUri": (root + "/") if root else "./",
                "packageUri": "lib/",
                "languageVersion": entry["language"],
            })
        rctx.file(filename, json.encode_indent({
            "configVersion": 2,
            "packages": packages,
            "generator": "rules_flutter pub_lock",
        }, indent = "  ") + "\n")

    # `flutter build bundle` also reads .dart_tool/package_graph.json (pub get's
    # other output). Everything in it is in each package's own pubspec.yaml.
    graph = []
    for name in sorted(entries.keys()):
        text = entries[name]["pubspec"]
        node = {"name": name, "version": pubspec_version(text), "dependencies": pubspec_dependencies(text)}
        if name == root_name:
            node["devDependencies"] = pubspec_dependencies(text, "dev_dependencies")
        graph.append(node)
    rctx.file("package_graph.json", json.encode_indent({
        "roots": [root_name],
        "packages": graph,
        "configVersion": 1,
    }, indent = "  ") + "\n")

    # The android plugin list `flutter pub get` writes to `.flutter-plugins-dependencies`,
    # derived from the pubspecs the hub already holds. Package locations are not in it:
    # they are `package_config.json`'s. Same semantics as flutter_tools'
    # `_createPluginMapOfPlatform`: `native_build` = pluginClass or ffiPlugin;
    # `dependencies` = the plugin's own dependencies that are android plugins;
    # `dev_dependency` = not reachable from the root's `dependencies`.
    deps = {name: pubspec_dependencies(entries[name]["pubspec"]) for name in entries}
    reached = {root_name: True}
    frontier = [root_name]
    for _ in range(len(entries)):
        nxt = []
        for name in frontier:
            for dep in deps[name]:
                if dep in entries and dep not in reached:
                    reached[dep] = True
                    nxt.append(dep)
        frontier = nxt
        if not frontier:
            break
    android = {}
    for name in sorted(entries.keys()):
        if name == root_name:
            continue
        info = pubspec_android_plugin(entries[name]["pubspec"])
        if info == None:
            continue
        if info.get("pluginClass") or info.get("dartPluginClass") or info.get("ffiPlugin") == "true":
            android[name] = info
    plugin_list = []
    for name in sorted(android.keys()):
        info = android[name]
        plugin_list.append({
            "name": name,
            "native_build": bool(info.get("pluginClass")) or info.get("ffiPlugin") == "true",
            "dependencies": [d for d in deps[name] if d in android],
            "dev_dependency": name not in reached,
        })
    rctx.file("plugins_metadata.json", json.encode_indent({
        "info": "generated by rules_flutter pub_lock from pubspec.yaml files",
        "plugins": {"android": plugin_list},
    }, indent = "  ") + "\n")

    hosted_names = sorted(rctx.attr.hosted.values())
    repo_of = {name: label.repo_name for label, name in rctx.attr.hosted.items()}

    # buildifier: disable=canonical-repository
    # `package_config.json` keeps `:lib` non-empty for an app with no hosted
    # dependency: a target with `allow_files` must produce a file.
    lib_srcs = ['"@@{}//:lib"'.format(repo_of[n]) for n in hosted_names] + ['"package_config.json"']

    # buildifier: disable=canonical-repository
    all_srcs = ['"@@{}//:all"'.format(repo_of[n]) for n in hosted_names] + ['"package_graph.json"']
    rctx.file("BUILD.bazel", """package(default_visibility = ["//visibility:public"])

exports_files(["package_config.json", "project_package_config.json", "package_graph.json", "plugins_metadata.json"])

filegroup(
    name = "lib",
    srcs = [{lib}],
)

filegroup(
    name = "all",
    srcs = [{all}],
)
""".format(lib = ", ".join(lib_srcs), all = ", ".join(all_srcs)))

def _root_package_name(pubspec_text):
    for raw in pubspec_text.split("\n"):
        if raw.startswith("name:"):
            return raw[len("name:"):].strip().strip("\"'")
    fail("pubspec.yaml: no top-level name")

pub_hub = repository_rule(
    implementation = _pub_hub_impl,
    doc = "The package configs, plugin metadata and file groups of one pubspec.lock.",
    attrs = {
        "lock": attr.label(allow_single_file = True, mandatory = True),
        "pubspec": attr.label(allow_single_file = True, mandatory = True),
        "hosted": attr.label_keyed_string_dict(allow_files = True),
        "sdk": attr.string_list(),
    },
)

def _pub_impl(mctx):
    hubs = {}
    for module in mctx.modules:
        for lock in module.tags.lock:
            if lock.name in hubs:
                fail("pub.lock: hub {} declared twice".format(lock.name))
            hubs[lock.name] = True

            resolved = resolve_lock(mctx.read(lock.lock))

            hosted = {}
            for package in resolved["hosted"]:
                repo = "{}_{}".format(lock.name, package["name"])
                _pub_archive(
                    name = repo,
                    urls = ["{server}/api/archives/{name}-{version}.tar.gz".format(
                        server = package["url"],
                        name = package["name"],
                        version = package["version"],
                    )],
                    sha256 = package["sha256"],
                    build_file_content = _PACKAGE_BUILD,
                )
                hosted["@{}//:pubspec.yaml".format(repo)] = package["name"]

            pub_hub(
                name = lock.name,
                lock = lock.lock,
                pubspec = lock.lock.same_package_label(lock.lock.name.rpartition("/")[0] + "/pubspec.yaml" if "/" in lock.lock.name else "pubspec.yaml"),
                hosted = hosted,
                sdk = [package["name"] for package in resolved["sdk"]],
            )

    return mctx.extension_metadata(reproducible = True)

_lock_tag = tag_class(
    doc = "One pubspec.lock and the hub repository generated from it.",
    attrs = {
        "name": attr.string(mandatory = True, doc = "Hub repository name, e.g. `pub`. Unique across every module using this extension."),
        "lock": attr.label(
            mandatory = True,
            allow_single_file = True,
            doc = "The project's pubspec.lock. pubspec.yaml must sit beside it.",
        ),
    },
)

pub = module_extension(
    implementation = _pub_impl,
    tag_classes = {"lock": _lock_tag},
)
