"""Generate pub hub metadata for checked-in plugin and namespace fixtures.

These packages are not in pubspec.lock. Match the hub format with
repository-relative rootUris for plugins.project.
"""

def _root_uri(marker):
    """The marker's directory as a rootUri relative to `external/<repository>/`."""
    directory = marker.package + "/" + marker.name.rpartition("/")[0]
    return "../../" + "/".join([s for s in directory.split("/") if s]) + "/"

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
        plugins.append({
            "name": name,
            "rootUri": _root_uri(marker),
            "native_build": True,
            "dependencies": [],
            "dev_dependency": False,
        })

    ctx.file(
        "plugins_metadata.json",
        json.encode({
            "info": "Generated namespace parser fixture metadata.",
            "plugins": {"android": [
                {key: plugin[key] for key in ["name", "native_build", "dependencies", "dev_dependency"]}
                for plugin in plugins
            ]},
        }),
    )
    ctx.file(
        "package_config.json",
        json.encode({
            "configVersion": 2,
            "packages": [
                {
                    "name": plugin["name"],
                    "rootUri": plugin["rootUri"],
                    "packageUri": "lib/",
                    "languageVersion": "3.0",
                }
                for plugin in plugins
            ],
        }),
    )
    ctx.file(
        "BUILD.bazel",
        "exports_files([\"plugins_metadata.json\", \"package_config.json\"])\n",
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
