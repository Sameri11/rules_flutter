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
"""

FlutterNativeInfo = provider(
    doc = "Native libraries a package contributes to the APK.",
    fields = {
        "jni_libs": "depset[File] of .so files to package as lib/<abi>/.",
    },
)

def _flutter_native_contribution_impl(ctx):
    libs = ctx.files.jni_libs

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

    for f in libs:
        if not f.basename.endswith(".so"):
            fail("{}: jni_libs may only contain .so files, got {}".format(
                ctx.label,
                f.basename,
            ))

    # The filename is load bearing twice over, and neither use is checked
    # anywhere else. A plugin's Kotlin calls System.loadLibrary("<name>", so the
    # file must be lib<name>.so; a code asset is named in the bundle's
    # NativeAssetsManifest.json by bare filename. Asserting here turns a silent
    # runtime miss into a build error.
    names = [f.basename for f in libs]
    for asset_id, expected in ctx.attr.code_assets.items():
        if expected not in names:
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
        FlutterNativeInfo(jni_libs = depset(libs)),
        DefaultInfo(files = depset(libs)),
    ]

flutter_native_contribution = rule(
    implementation = _flutter_native_contribution_impl,
    doc = """Declares what a recipe adds to the app beyond ordinary Java/Kotlin.

Every recipe must define one of these, named `<package>_flutter_native`. The
generated aggregate collects them by that name, so a recipe that forgets one
fails at analysis rather than producing a target nothing depends on.""",
    attrs = {
        "jni_libs": attr.label_list(
            allow_files = [".so"],
            doc = "Shared libraries to package as lib/<abi>/<name>.so.",
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
    jar = ctx.actions.declare_file(ctx.label.name + ".jar")

    libs = depset(transitive = [
        d[FlutterNativeInfo].jni_libs
        for d in ctx.attr.deps
    ]).to_list()

    # Two packages shipping the same soname would silently clobber each other
    # inside the jar, and whichever won would be a coin flip across rebuilds.
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
            abi = ctx.attr.abi,
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
        "abi": attr.string(default = "arm64-v8a"),
    },
)
