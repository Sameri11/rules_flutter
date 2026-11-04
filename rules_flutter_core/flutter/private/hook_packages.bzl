"""Private package identities for analysis-time native hook checks."""

visibility("public")

FlutterHookPackagesInfo = provider(
    doc = "Production package identities and directories for staged native build hooks.",
    fields = {
        "package_dirs": "dict from production package names to execroot-relative directories",
    },
)

def staged_hook_packages(package_dirs, staged_paths):
    staged = {path: True for path in staged_paths}
    return [
        name
        for name in sorted(package_dirs.keys())
        if ((package_dirs[name] + "/" if package_dirs[name] else "") + "hook/build.dart") in staged
    ]

def _flutter_hook_packages_impl(ctx):
    return [
        DefaultInfo(files = depset(ctx.files.srcs)),
        FlutterHookPackagesInfo(package_dirs = ctx.attr.package_dirs),
    ]

flutter_hook_packages = rule(
    implementation = _flutter_hook_packages_impl,
    attrs = {
        "srcs": attr.label_list(allow_files = True),
        "package_dirs": attr.string_dict(),
    },
)
