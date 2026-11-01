"""Android manifest and asset-path helpers used by composed app targets."""

load("@rules_flutter_core//flutter:defs.bzl", "FlutterPubspecInfo")

visibility(["//flutter"])

def _flutter_android_manifest_impl(ctx):
    out = ctx.actions.declare_file(ctx.label.name + "/AndroidManifest.xml")
    args = ctx.actions.args()
    pubspec = ctx.attr.pubspec[FlutterPubspecInfo]
    args.add(ctx.file._injector)
    args.add("--version-name", pubspec.version_name)
    args.add("--version-code", pubspec.version_code)
    args.add("--manifest", ctx.file.manifest)
    args.add("--out", out)
    ctx.actions.run_shell(
        command = 'exec python3 "$@"',
        arguments = [args],
        inputs = [
            pubspec.version_name,
            pubspec.version_code,
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
