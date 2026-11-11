"""Android manifest and asset-path helpers used by composed app targets."""

load("@rules_flutter_core//flutter:composition.bzl", "FlutterArtifactInfo", "FlutterPubspecInfo")
load("//flutter:abis.bzl", "ABIS")
load("//flutter/private:abis.bzl", "bazel_platform")

visibility(["//flutter"])
_ANDROID_DEFAULT_PLATFORM = bazel_platform(ABIS.keys()[0])

def _android_assets_platform_transition_impl(settings, _attr):
    android_platforms = settings["//command_line_option:android_platforms"]
    platforms = android_platforms[:1] if android_platforms else [_ANDROID_DEFAULT_PLATFORM]
    return {"//command_line_option:platforms": platforms}

_android_assets_platform_transition = transition(
    implementation = _android_assets_platform_transition_impl,
    inputs = ["//command_line_option:android_platforms"],
    outputs = ["//command_line_option:platforms"],
)

def _inputs_bundle_impl(ctx):
    (core,) = ctx.attr.core
    src = core[FlutterArtifactInfo].assets
    out = ctx.actions.declare_directory(ctx.label.name + "/flutter_assets")
    ctx.actions.run_shell(
        outputs = [out],
        inputs = [src],
        command = 'mkdir -p "{out}" && cp -RL "{src}"/. "{out}"/'.format(out = out.path, src = src.path),
        mnemonic = "FlutterAssetCopy",
        progress_message = "Copying the Flutter assets of %{label}",
    )
    return [DefaultInfo(files = depset([out]))]

_inputs_bundle = rule(
    implementation = _inputs_bundle_impl,
    doc = "The core's flutter_assets tree, copied under this target's name.",
    attrs = {
        "core": attr.label(mandatory = True, providers = [FlutterArtifactInfo], cfg = _android_assets_platform_transition),
    },
)

# Keep the private binding so this remains a rule kind, not a macro or alias.
flutter_android_assets = _inputs_bundle

def _flutter_android_manifest_impl(ctx):
    out = ctx.actions.declare_file(ctx.label.name + "/AndroidManifest.xml")
    args = ctx.actions.args()
    pubspec = ctx.attr.pubspec[FlutterPubspecInfo]
    args.add(ctx.file._injector)
    args.add("--version-name", pubspec.build_name)
    args.add("--version-code", pubspec.build_number)
    args.add("--manifest", ctx.file.manifest)
    args.add("--out", out)
    ctx.actions.run_shell(
        command = 'exec python3 "$@"',
        arguments = [args],
        inputs = [
            pubspec.build_name,
            pubspec.build_number,
            ctx.file.manifest,
            ctx.file._injector,
        ],
        outputs = [out],
        mnemonic = "FlutterAndroidManifest",
        progress_message = "Injecting pubspec version into AndroidManifest %{label}",
    )
    return [DefaultInfo(files = depset([out]))]

flutter_android_manifest = rule(
    implementation = _flutter_android_manifest_impl,
    doc = "Injects pubspec version facts into an Android manifest.",
    attrs = {
        "manifest": attr.label(allow_single_file = [".xml"], mandatory = True),
        "pubspec": attr.label(mandatory = True, providers = [FlutterPubspecInfo]),
        "_injector": attr.label(
            default = "//flutter/private:inject_version.py",
            allow_single_file = True,
        ),
    },
)

# buildifier: disable=unnamed-macro
def flutter_assets_dir(assets):
    """Returns android_binary's assets_dir for a flutter_assets target."""
    label = native.package_relative_label(assets)
    return "/".join([
        component
        for component in [label.workspace_root, label.package, label.name]
        if component
    ])
