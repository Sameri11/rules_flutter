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

    framework = ctx.path("pieces/framework_source")
    dart_archive = ctx.path("pieces/dart-sdk")
    dart = dart_archive.get_child("dart-sdk")
    patched = ctx.path("pieces/flutter_patched_sdk")
    patched_product = ctx.path("pieces/flutter_patched_sdk_product")
    sky = ctx.path("pieces/sky_engine")
    gpu = ctx.path("pieces/flutter_gpu")
    host = ctx.path("pieces/host_artifacts")
    font_subset = ctx.path("pieces/font_subset")
    fonts = ctx.path("pieces/material_fonts")
    gradle = ctx.path("pieces/gradle_wrapper")
    engine_stamp = ctx.path("pieces/engine_stamp.json")
    ctx.symlink(framework, "framework")
    ctx.symlink("framework/pubspec.yaml", "pubspec.yaml")
    ctx.symlink("framework/pubspec.lock", "pubspec.lock")
    ctx.symlink(dart, "bin/cache/dart-sdk")
    ctx.symlink("bin/cache/dart-sdk", "dart-sdk")
    ctx.symlink("framework/bin/flutter", "bin/flutter")
    ctx.symlink("framework/packages", "packages")
    ctx.symlink(patched.get_child("flutter_patched_sdk"), "bin/cache/artifacts/engine/common/flutter_patched_sdk")
    ctx.symlink(patched_product.get_child("flutter_patched_sdk_product"), "bin/cache/artifacts/engine/common/flutter_patched_sdk_product")
    ctx.symlink(sky.get_child("sky_engine"), "bin/cache/pkg/sky_engine")
    ctx.symlink(gpu, "bin/cache/pkg/flutter_gpu")
    ctx.symlink(host, "bin/cache/artifacts/engine/{}".format(ctx.attr.engine_host_dir))
    ctx.symlink(fonts, "bin/cache/artifacts/material_fonts")
    ctx.symlink(gradle, "bin/cache/artifacts/gradle_wrapper")
    for artifact in ctx.attr.ios_usb_names:
        piece = "ios_usb_" + artifact
        ctx.symlink(ctx.path("pieces/" + piece), "bin/cache/artifacts/" + artifact)
        ctx.file("bin/cache/{}.stamp".format(artifact), ctx.attr.ios_usb_versions[artifact])

    ctx.symlink(engine_stamp, "bin/cache/artifacts/engine/engine_stamp.json")
    for name in ("vm_isolate_snapshot.bin", "isolate_snapshot.bin", "flutter_tester", "icudtl.dat", "impellerc"):
        ctx.symlink(host.get_child(name), name)

    revision = ctx.attr.engine_revision
    for name in ("engine.stamp", "engine_stamp.stamp", "flutter_sdk.stamp", "font-subset.stamp"):
        ctx.file("bin/cache/" + name, revision + "\n" if name == "engine.stamp" else revision)
    ctx.file("bin/cache/material_fonts.stamp", ctx.attr.material_fonts_version)
    ctx.file("bin/cache/gradle_wrapper.stamp", ctx.attr.gradle_wrapper_version)
    ctx.file("bin/cache/engine.realm", "\n")
    devtools = json.decode(ctx.read(dart.get_child("bin/resources/devtools/version.json")))["version"]
    engine_metadata = json.decode(ctx.read(engine_stamp))
    ctx.file("bin/cache/flutter.version.json", json.encode({
        "frameworkVersion": ctx.attr.framework_version,
        "channel": "stable",
        "repositoryUrl": "https://github.com/flutter/flutter.git",
        "frameworkRevision": ctx.attr.framework_commit,
        "frameworkCommitDate": ctx.attr.framework_commit_date,
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
    globs += ["packages/**/packages/**/lib/**"]
    globs += ["packages/**/packages/**/pubspec.yaml"]
    globs += ["packages/**/packages/**/LICENSE*"]
    globs += ["packages/**/packages/**/NOTICES*"]

    build = """package(default_visibility = [\"//visibility:public\"])
exports_files([\"pubspec.yaml\", \"pubspec.lock\", \"packages/flutter_tools/bin/flutter_tools.dart\", \"dart\", \"dart_sdk_revision\", \"dartaotruntime\", \"vm_platform_strong.dill\", \"flutter\", \"frontend_server.snapshot\", \"flutter.version.json\", \"engine_stamp.json\", \"vm_isolate_snapshot.bin\", \"isolate_snapshot.bin\", \"flutter_tester\", \"icudtl.dat\", \"impellerc\"])
filegroup(name = \"dart_sdk_files\", srcs = glob([\"dart-sdk/**\"], allow_empty = True))
filegroup(name = \"platform_product\", srcs = glob([\"flutter_patched_sdk_product/**\"]))
filegroup(name = \"platform_debug\", srcs = glob([\"flutter_patched_sdk/**\"]))
filegroup(name = \"sdk_packages\", srcs = glob(%s, allow_empty = True))
filegroup(name = "flutter_tools_cache_state", srcs = [
    "bin/cache/engine.stamp",
    "bin/cache/engine_stamp.stamp",
    "bin/cache/flutter_sdk.stamp",
    "bin/cache/font-subset.stamp",
    "bin/cache/material_fonts.stamp",
    "bin/cache/gradle_wrapper.stamp",
    "bin/cache/engine.realm",
    "bin/cache/flutter.version.json",
    "bin/cache/artifacts/engine/engine_stamp.json",
] + glob(["pieces/**"], allow_empty = True) + %s)
""" % (
        repr(globs),
        repr(["bin/cache/{}.stamp".format(name) for name in ctx.attr.ios_usb_names]),
    )
    for name in [
        "framework_source_root",
        "dart_sdk_root",
        "patched_sdk_root",
        "patched_sdk_product_root",
        "sky_engine_root",
        "flutter_gpu_root",
        "host_artifacts_root",
        "font_subset_root",
        "material_fonts_root",
        "gradle_wrapper_root",
    ]:
        build += "filegroup(name = %s, srcs = [\"flutter.version.json\"])\n" % repr(name)
    for name in ctx.attr.ios_usb_names:
        piece = "ios_usb_" + name
        marker = "pieces/" + piece + "/.bazel_root"
        ctx.file(marker, "")
        build += "filegroup(name = %s, srcs = [%s])\n" % (
            repr("ios_usb_" + name.replace("-", "_") + "_root"),
            repr(marker),
        )
    ctx.file("BUILD.bazel", build)
    ctx.symlink("bin/cache/dart-sdk/bin/dart", "dart")
    ctx.symlink("bin/cache/dart-sdk/bin/dartaotruntime", "dartaotruntime")
    ctx.symlink("bin/cache/dart-sdk/revision", "dart_sdk_revision")
    ctx.symlink("bin/cache/dart-sdk/lib/_internal/vm_platform_strong.dill", "vm_platform_strong.dill")
    ctx.symlink("bin/cache/dart-sdk/bin/snapshots/frontend_server_aot.dart.snapshot", "frontend_server.snapshot")
    ctx.symlink("bin/cache/flutter.version.json", "flutter.version.json")
    ctx.symlink("bin/cache/artifacts/engine/engine_stamp.json", "engine_stamp.json")
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
        "framework_commit_date": attr.string(mandatory = True),
        "dart_sdk_version": attr.string(mandatory = True),
        "material_fonts_version": attr.string(mandatory = True),
        "gradle_wrapper_version": attr.string(mandatory = True),
    },
)
