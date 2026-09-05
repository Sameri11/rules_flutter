"""Deterministic jar helper for native libraries.

Uses Bazel's declared `zipper`, which fixes metadata and follows argv order.
`deterministic_jar` sorts entries and rejects `=`, zipper's member separator.
`StripNativeLibs` preserves input order because it discovers entries at execution.
"""

ZIPPER_ATTRS = {
    "_zipper": attr.label(
        default = Label("@bazel_tools//tools/zip:zipper"),
        executable = True,
        cfg = "exec",
        allow_single_file = True,
    ),
}

# `cC` creates a reproducibly deflated archive.
_CREATE_DEFLATED = "cC"

def deterministic_jar(ctx, jar, entries, mnemonic, progress_message):
    """Packages non-empty entries as a jar with fixed metadata.

    `entries` maps `lib/<abi>/<soname>` to Files; None writes an empty entry.
    """
    if not entries:
        fail("{}: deterministic_jar needs at least one entry".format(ctx.label))

    # Zipper uses `=` as the member separator.
    for name in sorted(entries):
        if "=" in name:
            fail(("{}: archive entry {} contains '='. zipper splits a member " +
                  "specification at the first '=', so this name cannot be " +
                  "packaged; rename the library.").format(ctx.label, name))

    fixed = ctx.actions.args()
    fixed.add(_CREATE_DEFLATED)
    fixed.add(jar)

    # Fix archive order independently of dict iteration.
    members = ctx.actions.args()
    members.add_all([
        "{}={}".format(name, entries[name].path if entries[name] else "")
        for name in sorted(entries)
    ])

    # Avoid command-line limits for large aggregates.
    members.use_param_file("@%s", use_always = False)
    members.set_param_file_format("multiline")

    ctx.actions.run(
        executable = ctx.executable._zipper,
        arguments = [fixed, members],
        inputs = [f for f in entries.values() if f],
        outputs = [jar],
        mnemonic = mnemonic,
        progress_message = progress_message,
    )
