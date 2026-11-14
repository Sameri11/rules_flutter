"""Analysis-time selection of files for a pub workspace member."""

visibility(["//flutter"])

PubWorkspaceInfo = provider(fields = ["members", "root"])

def _pub_workspace_impl(ctx):
    members = {}
    for i, path in enumerate(ctx.attr.member_paths):
        members[path] = struct(
            debug = ctx.files.member_debug[i],
            release = ctx.files.member_release[i],
            metadata = ctx.files.member_metadata[i],
            path_deps = ctx.files.member_path_deps[i],
        )
    return [PubWorkspaceInfo(
        members = members,
        root = struct(
            debug = ctx.file.root_debug,
            release = ctx.file.root_release,
            metadata = ctx.file.root_metadata,
            path_deps = ctx.file.root_path_deps,
        ),
    )]

pub_workspace = rule(
    implementation = _pub_workspace_impl,
    attrs = {
        "member_paths": attr.string_list(),
        "member_debug": attr.label_list(allow_files = [".dart"]),
        "member_release": attr.label_list(allow_files = [".dart"]),
        "member_metadata": attr.label_list(allow_files = [".json"]),
        "member_path_deps": attr.label_list(allow_files = [".json"]),
        "root_debug": attr.label(allow_single_file = [".dart"], mandatory = True),
        "root_release": attr.label(allow_single_file = [".dart"], mandatory = True),
        "root_metadata": attr.label(allow_single_file = [".json"], mandatory = True),
        "root_path_deps": attr.label(allow_single_file = [".json"], mandatory = True),
    },
)
