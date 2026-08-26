"""The contract between a package recipe and the app.

A *recipe* is a Starlark macro, written in the consuming project, that builds one
pub package the generated rules cannot describe -- a package whose native half is
downloaded rather than compiled, or that ships a Dart build hook instead of an
Android module. `//tools/flutter:plugins.bzl` generates a BUILD file that loads
the macro by canonical label and calls it; everything the macro then does happens
in the *user's* repo mapping, so a recipe can use rulesets this module has never
heard of. See docs_internal/package-recipes.md.

Two halves, and they are deliberately not symmetrical:

  * **In** is a plain `struct` in a generated `package_info.bzl`. It cannot be a
    provider -- a recipe is a macro, it runs during loading, and providers do not
    exist until analysis.

  * **Out** is `FlutterNativeInfo`, returned by a real target the recipe defines.

What a recipe contributes turned out to be smaller than it first looked. Both the
"downloaded jniLibs" and "Dart build hook" cases reduce to the same thing on
Android: get a `.so` into `lib/<abi>/` under a particular filename. Native assets
need no kernel flag and no generated manifest -- `flutter build bundle` already
writes a correct `NativeAssetsManifest.json`, and the engine reads it at runtime.
Measured; see the L5 section of the design note.

The shape
---------
One contribution per platform, with libraries keyed by *slice*.

A slice identifies one buildable variant of a platform: an ABI on Android, an
`.xcframework` LibraryIdentifier on Apple. Apple's identifiers are reused
verbatim, because a slice there is not an architecture -- device and simulator
differ by variant, and one slice can carry several architectures.

Platform is a target attribute rather than a prefix on a dict key because
`code_assets` maps an asset id to the name the VM resolves it by, and that name
is platform-specific. Bazel attributes cannot nest dicts, so the platform either
rides in the key as an encoding or moves up to the target. As an attribute with
a fixed value set, a typo names itself instead of surfacing later as a missing
library.
"""

# `dart_kernel`'s `target_os` names, not a second vocabulary. The list grows
# with the platform table; macOS is absent until there is something to build for
# it, and is named separately rather than folded into an `apple` -- flutter_tools
# keys the native-assets manifest that way, and the two resolve a code asset by
# different paths, so one entry covering both would have to be split later.
PLATFORMS = ["android", "ios"]

FlutterNativeInfo = provider(
    doc = "Native libraries a package contributes to one platform's bundle.",
    fields = {
        "platform": "str, one of PLATFORMS.",
        "libraries": "dict[str, depset[File]] keyed by slice.",
    },
)

def _flutter_native_contribution_impl(ctx):
    libraries = {
        slice_id: target[DefaultInfo].files.to_list()
        for slice_id, target in ctx.attr.libraries.items()
    }

    # An Apple slice identifier already begins with its platform name, so
    # checking that turns the redundancy into a cross-check: a bare arch, or
    # another platform's slice, is a copy-paste error and says so here.
    for slice_id in libraries:
        if ctx.attr.platform != "android" and not slice_id.startswith(ctx.attr.platform + "-"):
            fail("{}: slice '{}' does not belong to platform '{}'.".format(
                ctx.label,
                slice_id,
                ctx.attr.platform,
            ))

    libs = []
    for files in libraries.values():
        libs.extend(files)

    # A recipe that produces a well-formed target and no library is the exact
    # failure this milestone exists to prevent: it builds green and dies on the
    # first FFI call. Declaring emptiness is allowed; arriving at it silently is
    # not.
    if not libs and not ctx.attr.empty:
        fail(
            ("Recipe for {} contributed no native library.\n" +
             "If that is correct -- the package builds entirely from source, or " +
             "needs nothing at runtime -- pass empty = True to say so " +
             "deliberately. Otherwise the app will build and then fail on the " +
             "first call into this package.").format(ctx.label),
        )

    # The .so gate is Android's, not the contract's. An Apple contribution is a
    # .framework bundle with an Info.plist and a versioned layout, so the old
    # unconditional check rejected the *correct* Darwin artifact.
    if ctx.attr.platform == "android":
        for f in libs:
            if not f.basename.endswith(".so"):
                fail("{}: an android library must be a .so, got {}".format(
                    ctx.label,
                    f.basename,
                ))

    # The filename is load bearing twice over, and neither use is checked
    # anywhere else. A plugin's Kotlin calls System.loadLibrary("<name>", so the
    # file must be lib<name>.so; a code asset is named in the bundle's
    # NativeAssetsManifest.json by bare filename. Asserting here turns a silent
    # runtime miss into a build error.
    # A basename or a trailing path, because platforms name an asset
    # differently: a bare soname on Android, a path into a bundle on Apple.
    # Comparing basenames alone rejects the latter.
    names = [f.basename for f in libs]
    paths = [f.path for f in libs]

    def _contributed(expected):
        if expected in names:
            return True
        for path in paths:
            if path.endswith("/" + expected):
                return True
        return False

    for asset_id, expected in ctx.attr.code_assets.items():
        if not _contributed(expected):
            fail(
                ("Recipe for {} declares code asset\n  {}\n  -> {}\n" +
                 "but contributed no library with that name. Got: {}.\n" +
                 "The name must match the bundle's NativeAssetsManifest.json, " +
                 "which the Dart VM resolves the asset by.").format(
                    ctx.label,
                    asset_id,
                    expected,
                    ", ".join(names) if names else "(nothing)",
                ),
            )

    return [
        FlutterNativeInfo(
            platform = ctx.attr.platform,
            libraries = {s: depset(f) for s, f in libraries.items()},
        ),
        DefaultInfo(files = depset(libs)),
    ]

flutter_native_contribution = rule(
    implementation = _flutter_native_contribution_impl,
    doc = """Declares what a recipe adds to the app beyond ordinary Java/Kotlin.

Every recipe must define one of these, named `<package>_flutter_native`. The
generated aggregate collects them by that name, so a recipe that forgets one
fails at analysis rather than producing a target nothing depends on.""",
    attrs = {
        "platform": attr.string(
            default = "android",
            values = PLATFORMS,
            doc = """Platform this contribution targets.

One contribution per platform, rather than one carrying every platform's
fields. That keeps every attribute a simple type -- notably `code_assets`, whose
*value* is platform-specific (`libsqlite3.so` against
`sqlite3.framework/sqlite3`) and which Bazel cannot express as a nested dict.""",
        ),
        "libraries": attr.string_keyed_label_dict(
            allow_files = True,
            doc = """Slice -> the library for that slice.

On Android a slice is an ABI (`arm64-v8a`). On Apple it is an .xcframework
LibraryIdentifier (`ios-arm64`, `ios-arm64_x86_64-simulator`), used verbatim so
the key matches the directory the artifact ships in.""",
        ),
        "code_assets": attr.string_dict(
            doc = """Dart native-asset id -> the .so filename the VM resolves it by.

Only for packages with a build hook. Not used to *generate* anything -- the
bundle already carries the authoritative mapping -- but checked against
`jni_libs`, so a renamed or missing library is caught here.""",
        ),
        "empty": attr.bool(
            default = False,
            doc = "Assert deliberately that this package contributes no library.",
        ),
    },
)

def _flutter_native_libs_impl(ctx):
    # Android's packaging shape, and only Android's: this stages `lib/<slice>/`
    # and zips a jar, because that is how android_binary finds native libraries
    # on the classpath. An Apple slice needs a framework inside a bundle, which
    # is a different action, not a different attribute value -- so `ios` is
    # refused here rather than silently producing an Android-shaped jar that
    # nothing on Apple would read.
    if ctx.attr.platform != "android":
        fail(("{}: flutter_native_libs packages Android jars, but platform is " +
              "'{}'. The Apple bundle step does not exist yet; contributions " +
              "for it are declared (flutter_native_contribution) but cannot be " +
              "aggregated.").format(ctx.label, ctx.attr.platform))

    jar = ctx.actions.declare_file(ctx.label.name + ".jar")

    # A contribution for another platform reaching this aggregate is a recipe
    # bug. Filtering it out silently would yield a bundle missing a library --
    # the failure this file exists to prevent -- so it is named here.
    for d in ctx.attr.deps:
        got = d[FlutterNativeInfo].platform
        if got != ctx.attr.platform:
            fail("{}: contribution {} targets platform '{}', but this bundle is '{}'.".format(
                ctx.label,
                d.label,
                got,
                ctx.attr.platform,
            ))

    libs = depset(transitive = [
        d[FlutterNativeInfo].libraries.get(ctx.attr.slice, depset())
        for d in ctx.attr.deps
    ]).to_list()

    # Contributing something, but nothing for the slice being built, is not the
    # same as deliberately contributing nothing.
    for d in ctx.attr.deps:
        have = d[FlutterNativeInfo].libraries
        if have and ctx.attr.slice not in have:
            fail("{}: contribution {} has no library for slice '{}'; it has {}.".format(
                ctx.label,
                d.label,
                ctx.attr.slice,
                sorted(have),
            ))

    # Two packages shipping the same soname would silently clobber each other
    # inside the jar, and whichever won would be a coin flip across rebuilds.
    # Scoped to one slice: a package legitimately ships the same soname per
    # ABI, and comparing across slices would reject that.
    seen = {}
    for f in libs:
        if f.basename in seen:
            fail("Two recipes contribute {}: {} and {}".format(
                f.basename,
                seen[f.basename],
                f.path,
            ))
        seen[f.basename] = f.path

    # Same mechanism as jni_lib_jar: android_binary extracts lib/<abi>/*.so from
    # jars on the classpath, which is how the prebuilt engine artifact ships
    # libflutter.so and how libapp.so is packaged. Recipe output rides the same
    # path rather than needing one of its own.
    #
    # Not stripped, deliberately -- unlike android_native_lib_jar, which strips
    # what it just compiled, these are vendor prebuilts. Stripping them would
    # need a cc_toolchain (and so a platform transition) to reach llvm-strip, to
    # discard symbols the vendor already chose to ship.
    ctx.actions.run_shell(
        command = """set -euo pipefail
STAGE="$(mktemp -d "${{TMPDIR:-/tmp}}/flutternativelibs.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/lib/{abi}"
for so in {sos}; do
    cp "$so" "$STAGE/lib/{abi}/"
done
chmod -R u+w "$STAGE"
( cd "$STAGE" && zip -q -X -r "$OLDPWD/{jar}" lib )
""".format(
            # `lib/<slice>/` is Android's layout, and on Android a slice *is* an
            # ABI -- which is why this used to be a second attribute carrying
            # the same string. An Apple bundle lays its slices out differently
            # and will need its own packaging step, not another attribute here.
            abi = ctx.attr.slice,
            sos = " ".join(['"{}"'.format(f.path) for f in libs]),
            jar = jar.path,
        ),
        inputs = libs,
        outputs = [jar],
        mnemonic = "FlutterNativeLibs",
        progress_message = "Packaging recipe native libraries %{label}",
    )

    # A plain jar. The generated repo wraps it in java_import, exactly as
    # app/android/app does for libapp.so -- constructing JavaInfo here would
    # duplicate that for no gain.
    return [DefaultInfo(files = depset([jar]))]

flutter_native_libs = rule(
    implementation = _flutter_native_libs_impl,
    doc = """Collects every recipe's native libraries into one jar for android_binary.

Instantiated in the generated @flutter_plugins repository, not written by hand,
and wrapped there in a java_import the app can depend on directly.""",
    attrs = {
        "deps": attr.label_list(
            providers = [FlutterNativeInfo],
            doc = "flutter_native_contribution targets, one per recipe.",
        ),
        "platform": attr.string(
            default = "android",
            values = PLATFORMS,
            doc = "Platform being bundled; contributions must agree.",
        ),
        "slice": attr.string(
            mandatory = True,
            doc = """Which slice of each contribution to take, and on Android the
lib/<abi>/ directory libraries are packaged under. See FlutterNativeInfo.

Mandatory: a default here packages one architecture's libraries as another's,
which nothing downstream can detect.

Not checked against abi_from_platform: this rule does not transition --platforms,
so its ambient configuration is the caller's, not this slice's.""",
        ),
    },
)
