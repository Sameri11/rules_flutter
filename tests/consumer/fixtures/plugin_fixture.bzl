"""Generate pub hub metadata for checked-in plugin and namespace fixtures.

These packages are not in pubspec.lock. Match the hub format with
repository-relative rootUris for plugins.project.
"""

def _root_uri(marker):
    """The marker's directory as a rootUri relative to `external/<repository>/`."""
    directory = marker.package + "/" + marker.name.rpartition("/")[0]
    return "../../" + "/".join([s for s in directory.split("/") if s]) + "/"

def _namespace_plugin_metadata_impl(ctx):
    """Generate platform plugin metadata for checked-in fixture packages."""
    plugins = []
    for name, marker, package, plugin_class in [
        ("namespace_bare", ctx.attr.bare_marker, "com.example.namespace_bare", "Plugin"),
        ("namespace_call", ctx.attr.call_marker, "com.example.namespace_call", "Plugin"),
        ("namespace_assignment", ctx.attr.assignment_marker, "com.example.namespace_assignment", "Plugin"),
        ("namespace_guarded", ctx.attr.guarded_marker, "com.example.namespace_guarded", "Plugin"),
        ("fake_plugin", ctx.attr.fake_marker, "com.example.fake_plugin", "FakePlugin"),
        ("build_config_plugin", ctx.attr.build_config_marker, "com.example.build_config_plugin", "BuildConfigPlugin"),
    ]:
        plugins.append({
            "name": name,
            "rootUri": _root_uri(marker),
            "native_build": True,
            "dependencies": [],
            "direct": True,
            "dev_dependency": False,
            "implements": "",
            "default_package": None,
            "package": package,
            "plugin_class": plugin_class,
        })

    ctx.file(
        "plugins_metadata.json",
        json.encode({
            "info": "Generated namespace parser fixture metadata.",
            "plugins": {"android": [
                {key: plugin[key] for key in [
                    "name",
                    "native_build",
                    "dependencies",
                    "direct",
                    "dev_dependency",
                    "implements",
                    "default_package",
                    "package",
                    "plugin_class",
                ]}
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
        "exports_files({})\n".format(repr([
            "plugins_metadata.json",
            "package_config.json",
        ])),
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
