"""Assembles independently pinned SDK pieces into Flutter's cache layout."""

visibility(["//flutter"])

def _sdk_tree_impl(ctx):
    downloads = {}
    ctx.file("downloads/.keep", "")
    ctx.file("pieces/.keep", "")
    for piece, urls in ctx.attr.urls.items():
        downloads[piece] = ctx.download(
            url = urls,
            output = "downloads/" + piece,
            sha256 = ctx.attr.sha256[piece],
            block = False,
        )
    for piece, download in downloads.items():
        result = download.wait()
        if not result.success:
            fail("Could not download Flutter SDK piece {}: {}".format(piece, result))
    for piece in downloads:
        archive = "downloads/" + piece
        if piece == "engine_stamp":
            ctx.rename(archive, "pieces/engine_stamp.json")
        else:
            ctx.extract(
                archive,
                output = "pieces/" + piece,
                type = ctx.attr.archive_types[piece],
                strip_prefix = ctx.attr.strip_prefixes[piece],
            )
    layout = []

    def add_layout(destination, source):
        layout.append({"destination": destination, "source": source})

    add_layout("framework", "framework_source")
    framework_names = [entry.basename for entry in ctx.path("pieces/framework_source").readdir()]
    for name in framework_names:
        if name != "bin" and name != "packages":
            add_layout(name, "framework_source/" + name)
    for entry in ctx.path("pieces/framework_source/bin").readdir():
        if entry.basename not in ("cache", "flutter"):
            add_layout("bin/" + entry.basename, "framework_source/bin/" + entry.basename)
    for entry in ctx.path("pieces/framework_source/packages").readdir():
        if entry.basename != "flutter_tools":
            add_layout("packages/" + entry.basename, "framework_source/packages/" + entry.basename)
    for entry in ctx.path("pieces/framework_source/packages/flutter_tools").readdir():
        add_layout("packages/flutter_tools/" + entry.basename, "framework_source/packages/flutter_tools/" + entry.basename)
    for destination, source in [
        ("bin/cache/dart-sdk", "dart-sdk/dart-sdk"),
        ("dart-sdk", "dart-sdk/dart-sdk"),
        ("bin/cache/artifacts/engine/common/flutter_patched_sdk", "flutter_patched_sdk/flutter_patched_sdk"),
        ("bin/cache/artifacts/engine/common/flutter_patched_sdk_product", "flutter_patched_sdk_product/flutter_patched_sdk_product"),
        ("bin/cache/artifacts/engine/" + ctx.attr.engine_host_dir, "host_artifacts"),
        ("bin/cache/pkg/sky_engine", "sky_engine/sky_engine"),
        ("bin/cache/pkg/flutter_gpu", "flutter_gpu"),
        ("bin/cache/artifacts/material_fonts", "material_fonts"),
        ("bin/cache/engine_stamp.json", "engine_stamp.json"),
        ("vm_isolate_snapshot.bin", "host_artifacts/vm_isolate_snapshot.bin"),
        ("isolate_snapshot.bin", "host_artifacts/isolate_snapshot.bin"),
        ("flutter_tester", "host_artifacts/flutter_tester"),
        ("icudtl.dat", "host_artifacts/icudtl.dat"),
        ("impellerc", "host_artifacts/impellerc"),
        ("bin/cache/artifacts/gradle_wrapper", "gradle_wrapper"),
    ]:
        add_layout(destination, source)
    for artifact in ctx.attr.ios_usb_names:
        add_layout("bin/cache/artifacts/" + artifact, "ios_usb_" + artifact)
        ctx.file("pieces/generated/" + artifact + ".stamp", ctx.attr.ios_usb_versions[artifact])
        add_layout("bin/cache/" + artifact + ".stamp", "generated/" + artifact + ".stamp")
    revision = ctx.attr.engine_revision
    for name in ("engine.stamp", "engine_stamp.stamp", "flutter_sdk.stamp", "font-subset.stamp"):
        ctx.file("pieces/generated/" + name, revision + "\n" if name == "engine.stamp" else revision)
        add_layout("bin/cache/" + name, "generated/" + name)
    for name, value in (("material_fonts.stamp", ctx.attr.material_fonts_version),):
        ctx.file("pieces/generated/" + name, value)
        add_layout("bin/cache/" + name, "generated/" + name)
    ctx.file("pieces/generated/gradle_wrapper.stamp", ctx.attr.gradle_wrapper_version)
    add_layout("bin/cache/gradle_wrapper.stamp", "generated/gradle_wrapper.stamp")
    ctx.file("pieces/generated/flutter", "#!/bin/sh\nFLUTTER_ROOT=\"$(cd \"$(dirname \"$0\")/..\" && pwd)\"\nexport FLUTTER_ROOT\nexec \"$FLUTTER_ROOT/framework/bin/flutter\" \"$@\"\n", executable = True)
    add_layout("bin/flutter", "generated/flutter")
    ctx.file("pieces/generated/engine.realm", "\n")
    add_layout("bin/cache/engine.realm", "generated/engine.realm")
    ctx.file("sdk_layout.json", json.encode(layout) + "\n")

    dart = ctx.path("pieces/dart-sdk/dart-sdk")
    engine_stamp = ctx.path("pieces/engine_stamp.json")
    for entry in layout:
        ctx.symlink(ctx.path("pieces/" + entry["source"]), entry["destination"])

    revision = ctx.attr.engine_revision
    devtools = json.decode(ctx.read(dart.get_child("bin/resources/devtools/version.json")))["version"]
    engine_metadata = json.decode(ctx.read(engine_stamp))
    ctx.file("bin/cache/flutter.version.json", json.encode({
        "frameworkVersion": ctx.attr.framework_version,
        "channel": "stable",
        "repositoryUrl": "https://github.com/flutter/flutter.git",
        "frameworkRevision": ctx.attr.framework_commit,
        "frameworkCommitDate": "",
        "engineRevision": revision,
        "engineCommitDate": engine_metadata["git_revision_date"],
        "engineContentHash": ctx.attr.engine_content_hash,
        "engineBuildDate": engine_metadata["build_date"],
        "dartSdkVersion": ctx.attr.dart_sdk_version,
        "devToolsVersion": devtools,
        "flutterVersion": ctx.attr.framework_version,
    }) + "\n")
    ctx.file("bin/internal/material_fonts.version", ctx.attr.material_fonts_version + "\n")
    ctx.file("bin/internal/gradle_wrapper.version", ctx.attr.gradle_wrapper_version + "\n")

    # Flutter package names are derived from the pinned source tree.
    package_roots = ["packages/" + p.basename for p in ctx.path("framework/packages").readdir() if ctx.path("framework/packages/" + p.basename + "/pubspec.yaml").exists]
    package_roots.append("bin/cache/pkg/sky_engine")
    globs = [r + "/lib/**" for r in package_roots]
    globs += [r + "/pubspec.yaml" for r in package_roots]
    globs += [r + "/LICENSE*" for r in package_roots]
    globs += [r + "/NOTICES*" for r in package_roots]
    globs.extend([
        "packages/**/packages/**/lib/**",
        "packages/**/packages/**/pubspec.yaml",
        "packages/**/packages/**/LICENSE*",
        "packages/**/packages/**/NOTICES*",
    ])

    build = """package(default_visibility = [\"//visibility:public\"])
exports_files(["sdk_layout.json"])
exports_files(["pubspec.yaml", "pubspec.lock", "packages/flutter_tools/bin/flutter_tools.dart", "dart", "dart_sdk_revision", "dartaotruntime", "vm_platform_strong.dill", "flutter", "frontend_server.snapshot", "flutter.version.json", "engine_stamp.json", "vm_isolate_snapshot.bin", "isolate_snapshot.bin", "flutter_tester", "icudtl.dat", "impellerc"])
filegroup(name = "dart_sdk_files", srcs = glob(["dart-sdk/**"], allow_empty = True))
filegroup(name = "platform_product", srcs = glob(["flutter_patched_sdk_product/**"]))
filegroup(name = "platform_debug", srcs = glob(["flutter_patched_sdk/**"]))
filegroup(name = "sdk_packages", srcs = glob(%s, allow_empty = True))
filegroup(name = "framework_tools_lib", srcs = glob(["packages/flutter_tools/lib/**"], allow_empty = True))
filegroup(name = "flutter_tools_cache_state", srcs = [
    "bin/cache/engine.stamp",
    "bin/cache/engine_stamp.stamp",
    "bin/cache/flutter_sdk.stamp",
    "bin/cache/font-subset.stamp",
    "bin/cache/material_fonts.stamp",
    "bin/cache/gradle_wrapper.stamp",
    "bin/cache/engine.realm",
    "bin/cache/flutter.version.json",
    "bin/cache/engine_stamp.json",
] + glob(["pieces/**"], allow_empty = True) + %s)
""" % (
        repr(globs),
        repr(["bin/cache/{}.stamp".format(name) for name in ctx.attr.ios_usb_names]),
    )
    ctx.file("BUILD.bazel", build)
    ctx.symlink("bin/cache/dart-sdk/bin/dart", "dart")
    ctx.symlink("bin/cache/dart-sdk/bin/dartaotruntime", "dartaotruntime")
    ctx.symlink("bin/cache/dart-sdk/revision", "dart_sdk_revision")
    ctx.symlink("bin/cache/dart-sdk/lib/_internal/vm_platform_strong.dill", "vm_platform_strong.dill")
    ctx.symlink("bin/cache/dart-sdk/bin/snapshots/frontend_server_aot.dart.snapshot", "frontend_server.snapshot")
    ctx.symlink("bin/cache/flutter.version.json", "flutter.version.json")
    ctx.symlink("bin/cache/engine_stamp.json", "engine_stamp.json")
    ctx.symlink("bin/flutter", "flutter")
    ctx.symlink("bin/cache/artifacts/engine/common/flutter_patched_sdk", "flutter_patched_sdk")
    ctx.symlink("bin/cache/artifacts/engine/common/flutter_patched_sdk_product", "flutter_patched_sdk_product")

sdk_tree = repository_rule(
    implementation = _sdk_tree_impl,
    attrs = {
        "urls": attr.string_list_dict(mandatory = True),
        "sha256": attr.string_dict(mandatory = True),
        "archive_types": attr.string_dict(mandatory = True),
        "strip_prefixes": attr.string_dict(mandatory = True),
        "ios_usb_names": attr.string_list(),
        "ios_usb_versions": attr.string_dict(),
        "engine_host_dir": attr.string(mandatory = True),
        "engine_revision": attr.string(mandatory = True),
        "engine_content_hash": attr.string(mandatory = True),
        "framework_version": attr.string(mandatory = True),
        "framework_commit": attr.string(mandatory = True),
        "dart_sdk_version": attr.string(mandatory = True),
        "material_fonts_version": attr.string(mandatory = True),
        "gradle_wrapper_version": attr.string(mandatory = True),
    },
)
