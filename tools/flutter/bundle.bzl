"""What a Flutter app contributes to a platform bundle, named.

An app is assembled from a fixed set of contributions -- the AOT snapshot, the
engine, the runtime classes, the assets, the plugins, the recipe libraries, the
registrant. The set is the same on every platform; only where each one lands and
what shape it takes differ.

Naming them is what lets the platform-specific half be rewritten without
rediscovering the list. It follows rules_apple's partials, where every partial
returns the same shape so the bundling processor stays generic.

Two things this deliberately does not do:

  * It does not package anything. Android packaging is `android_binary`, which
    reads ordinary `deps` and `assets`, so contributions are wired into it
    natively rather than through a processor of our own.

  * It does not replace the real dependency edges. Each contribution carries
    metadata alongside the target doing the work, leaving the packaging graph
    untouched and giving a checker something to inspect. A macro cannot fail at
    analysis and a rule cannot instantiate `java_import`, so the join is a macro
    that assembles plus a rule that checks.
"""

# Where a contribution's files land -- named for the destination, not for the
# contribution, so a platform putting two in the same place says so.
#
# NATIVE_LIB  a shared library the loader must find.
# ASSETS      the flutter_assets tree.
# CLASSES     classes reaching the dex; empty on platforms with no JVM.
NATIVE_LIB = "native_lib"

ASSETS = "assets"

CLASSES = "classes"

LOCATIONS = [NATIVE_LIB, ASSETS, CLASSES]

FlutterBundleContributionInfo = provider(
    doc = "One named contribution to a platform bundle.",
    fields = {
        "kind": "str, the contribution's name -- 'aot_library', 'engine', ...",
        "location": "str, one of LOCATIONS: where its files land.",
        "files": "depset[File] it contributes, across every slice.",
        "libraries": "dict[str, depset[File]] keyed by slice; empty when the " +
                     "contribution does not vary by slice.",
        "empty": "bool, set when this platform deliberately contributes nothing.",
    },
)

def _flutter_bundle_contribution_impl(ctx):
    # Keyed by slice rather than flattened: a jar carrying the wrong
    # architecture is invisible in a flat list, being a file that is present
    # under a path nobody compared. Slice is recipe.bzl's vocabulary.
    libraries = {
        slice_id: depset(target[DefaultInfo].files.to_list())
        for slice_id, target in ctx.attr.libraries.items()
    }

    if ctx.files.srcs and libraries:
        fail(
            ("Bundle contribution {} ({}) sets both `srcs` and `libraries`.\n" +
             "A contribution either varies by slice or it does not; setting " +
             "both leaves no answer to which slice `srcs` belongs to.").format(
                ctx.label,
                ctx.attr.kind,
            ),
        )

    files = depset(ctx.files.srcs, transitive = libraries.values())

    # Same rule recipe.bzl applies to native libraries, for the same reason: a
    # contribution that silently resolves to nothing produces an app that
    # builds, installs, launches and is missing a piece. Declaring emptiness is
    # allowed; arriving at it by accident is not.
    if not files.to_list() and not ctx.attr.empty:
        fail(
            ("Bundle contribution {} ({}) resolved to no files.\n" +
             "If this platform genuinely contributes nothing here, pass " +
             "empty = True to say so deliberately.").format(
                ctx.label,
                ctx.attr.kind,
            ),
        )

    return [
        FlutterBundleContributionInfo(
            kind = ctx.attr.kind,
            location = ctx.attr.location,
            files = files,
            libraries = libraries,
            empty = ctx.attr.empty,
        ),
        DefaultInfo(files = files),
    ]

flutter_bundle_contribution = rule(
    implementation = _flutter_bundle_contribution_impl,
    doc = """Declares one named contribution to the bundle.

Instantiated by a platform's join macro, not written by hand. It carries
metadata about a contribution the packaging rule already receives through
ordinary deps -- so it adds a name and a check, and changes nothing about how
the artifact is built.""",
    attrs = {
        "kind": attr.string(mandatory = True),
        "location": attr.string(mandatory = True, values = LOCATIONS),
        "srcs": attr.label_list(
            allow_files = True,
            doc = "Files contributed whatever slice is being built.",
        ),
        "libraries": attr.string_keyed_label_dict(
            allow_files = True,
            doc = """Slice -> what this contribution supplies for that slice.

For contributions that exist once per buildable variant -- every native library
on Android. Same slice identifier recipe.bzl uses.""",
        ),
        "empty": attr.bool(
            default = False,
            doc = "Assert deliberately that this platform contributes nothing here.",
        ),
    },
)
