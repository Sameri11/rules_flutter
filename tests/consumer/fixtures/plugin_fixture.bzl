"""Synthesizes portable metadata for the fake plugin and namespace fixtures.

Pub writes absolute package paths into both metadata files, so checked-in copies
are machine-specific. Resolve each marker at fetch time and generate only those
files; the plugin sources remain checked in.
"""

def _namespace_plugin_metadata_impl(ctx):
    """Generate pub metadata for namespace and BuildConfig fixtures."""
    plugins = []
    for name, marker in [
        ("namespace_bare", ctx.attr.bare_marker),
        ("namespace_call", ctx.attr.call_marker),
        ("namespace_assignment", ctx.attr.assignment_marker),
        ("namespace_guarded", ctx.attr.guarded_marker),
        ("fake_plugin", ctx.attr.fake_marker),
        ("build_config_plugin", ctx.attr.build_config_marker),
    ]:
        root = str(ctx.path(marker).dirname)
        plugins.append({
            "name": name,
            "path": root + "/",
            "native_build": True,
            "dependencies": [],
            "dev_dependency": False,
        })

    ctx.file(
        ".flutter-plugins-dependencies",
        json.encode({
            "info": "Generated namespace parser fixture metadata.",
            "plugins": {"android": plugins},
        }),
    )
    ctx.file(
        "package_config.json",
        json.encode({
            "configVersion": 2,
            "packages": [
                {
                    "name": plugin["name"],
                    "rootUri": "file://" + plugin["path"].rstrip("/"),
                    "packageUri": "lib/",
                    "languageVersion": "3.0",
                }
                for plugin in plugins
            ],
        }),
    )
    ctx.file(
        "BUILD.bazel",
        "exports_files([\".flutter-plugins-dependencies\", \"package_config.json\"])\n",
    )

namespace_plugin_metadata = repository_rule(
    implementation = _namespace_plugin_metadata_impl,
    attrs = {
        "bare_marker": attr.label(
            allow_single_file = True,
            mandatory = True,
        ),
        "call_marker": attr.label(
            allow_single_file = True,
            mandatory = True,
        ),
        "assignment_marker": attr.label(
            allow_single_file = True,
            mandatory = True,
        ),
        "guarded_marker": attr.label(
            allow_single_file = True,
            mandatory = True,
        ),
        "fake_marker": attr.label(
            allow_single_file = True,
            mandatory = True,
        ),
        "build_config_marker": attr.label(
            allow_single_file = True,
            mandatory = True,
        ),
    },
)
