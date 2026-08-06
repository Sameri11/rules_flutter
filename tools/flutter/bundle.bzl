"""What a Flutter app contributes to a platform bundle, named.

An app is assembled from a fixed set of contributions -- the AOT snapshot, the
engine, the runtime classes, the assets, the plugins, the recipe libraries, the
registrant. That set is the same on every platform; only *where each one lands*
and *what shape it takes* differ. On Android the assets sit beside the code in
`assets/flutter_assets/` and a native library rides inside a jar; on Apple the
assets are inside `App.framework/` and the AOT snapshot *is* the framework
binary.

Naming the contributions is what lets the platform-specific half be rewritten
without rediscovering the list. It follows rules_apple's `partials/`, where every
partial returns the same struct shape and the bundling processor stays generic.

Two things this deliberately does **not** do:

  * It does not package anything. On Android the packaging is `android_binary`,
    which reads ordinary `deps`/`assets`, so the contributions are wired into it
    natively rather than through a processor of our own.

  * It does not replace the real dependency edges. Each contribution carries
    metadata *alongside* the target that does the work, so the packaging graph is
    unchanged and a bundle checker has something to inspect. A macro cannot fail
    at analysis, and a rule cannot instantiate `java_import` -- so the join is a
    macro that assembles, plus a rule that checks.
"""

# Where a contribution's files land. Named for the destination, not for the
# partial, so a platform that puts two contributions in the same place says so.
#
# NATIVE_LIB  a shared library the loader must find: lib/<abi>/ on Android,
#             the framework binary or Contents/Frameworks/ on Apple.
# ASSETS      the flutter_assets tree.
# CLASSES     JVM classes reaching the dex. Android-only by construction --
#             on Apple the runtime is inside Flutter.framework and the
#             corresponding contribution is empty.
NATIVE_LIB = "native_lib"

ASSETS = "assets"

CLASSES = "classes"

LOCATIONS = [NATIVE_LIB, ASSETS, CLASSES]

FlutterBundleContributionInfo = provider(
    doc = "One named contribution to a platform bundle.",
    fields = {
        "kind": "str, the contribution's name -- 'aot_library', 'engine', ...",
        "location": "str, one of LOCATIONS: where its files land.",
        "files": "depset[File] it contributes. Empty is legal only when `empty`.",
        "empty": "bool, set when this platform deliberately contributes nothing.",
    },
)

def _flutter_bundle_contribution_impl(ctx):
    files = depset(ctx.files.srcs)

    # The same rule recipe.bzl applies to native libraries, for the same reason:
    # a contribution that silently resolves to nothing produces an app that
    # builds, installs and launches, and is missing a piece. Declaring emptiness
    # is allowed; arriving at it by accident is not. VI.2's row 3 -- runtime
    # classes, a real contribution on Android and empty on Apple -- is what this
    # exists for.
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
        "srcs": attr.label_list(allow_files = True),
        "empty": attr.bool(
            default = False,
            doc = "Assert deliberately that this platform contributes nothing here.",
        ),
    },
)
