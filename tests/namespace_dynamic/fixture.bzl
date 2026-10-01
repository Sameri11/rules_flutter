"""Generates pub hub files for the isolated dynamic namespace fixture.

Same shape as tests/consumer/fixtures/plugin_fixture.bzl: `plugins_metadata.json`
and a `package_config.json` whose rootUri is relative to the repository.
"""

def _dynamic_namespace_metadata_impl(ctx):
    marker = ctx.attr.marker
    directory = marker.package + "/" + marker.name.rpartition("/")[0]
    root = "../../" + "/".join([s for s in directory.split("/") if s]) + "/"
    ctx.file(
        "plugins_metadata.json",
        json.encode({
            "info": "Generated dynamic namespace parser fixture metadata.",
            "plugins": {"android": [{
                "name": "namespace_dynamic",
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
                "rootUri": root,
                "packageUri": "lib/",
                "languageVersion": "3.0",
            }],
        }),
    )
    ctx.file(
        "BUILD.bazel",
        "exports_files([\"plugins_metadata.json\", \"package_config.json\"])\n",
    )

dynamic_namespace_metadata = repository_rule(
    implementation = _dynamic_namespace_metadata_impl,
    attrs = {"marker": attr.label(allow_single_file = True, mandatory = True)},
)
