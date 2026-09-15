"""Generates pub metadata for the isolated dynamic namespace fixture."""

def _dynamic_namespace_metadata_impl(ctx):
    root = str(ctx.path(ctx.attr.marker).dirname)
    ctx.file(
        ".flutter-plugins-dependencies",
        json.encode({
            "info": "Generated dynamic namespace parser fixture metadata.",
            "plugins": {"android": [{
                "name": "namespace_dynamic",
                "path": root + "/",
                "native_build": True,
                "dependencies": [],
                "dev_dependency": False,
            }]},
        }),
    )
    ctx.file(
        "package_config.json",
        json.encode({
            "configVersion": 2,
            "packages": [{
                "name": "namespace_dynamic",
                "rootUri": "file://" + root,
                "packageUri": "lib/",
                "languageVersion": "3.0",
            }],
        }),
    )
    ctx.file(
        "BUILD.bazel",
        "exports_files([\".flutter-plugins-dependencies\", \"package_config.json\"])\n",
    )

dynamic_namespace_metadata = repository_rule(
    implementation = _dynamic_namespace_metadata_impl,
    attrs = {"marker": attr.label(allow_single_file = True, mandatory = True)},
)
