"""Rules for the Android half of a Flutter build.

Half 2 of the decomposition in defs.bzl: taking `libapp.so`, the engine, the
plugin libraries and the asset bundle and getting them into an APK. Everything
here is Android-specific -- the jar-on-the-classpath mechanism `android_binary`
uses to pick up native libraries, the NDK strip, and the guard that ties the
asset bundle's code assets to the libraries a recipe supplied.

Kept apart from defs.bzl so a consumer building for another platform does not
load Android rules to get `dart_kernel`. The cc toolchain dependency lives
entirely on this side.
"""

load("@flutter_sdk//:sdk.bzl", "FLUTTER_ENV")
load("@rules_cc//cc:find_cc_toolchain.bzl", "find_cpp_toolchain", "use_cc_toolchain")

def _native_assets_check_impl(ctx):
    marker = ctx.actions.declare_file(ctx.label.name + ".checked")

    # The manifest lives inside the asset tree artifact, so its path is derived
    # rather than declared. flutter_tools writes it at the bundle root --
    # `additionalContent: {'NativeAssetsManifest.json': ...}` in
    # build_system/targets/common.dart.
    manifest = ctx.file.assets.path + "/NativeAssetsManifest.json"

    args = ctx.actions.args()
    args.add(ctx.file._checker)
    args.add("--manifest", manifest)
    args.add("--jar", ctx.file.native_libs)
    args.add("--out", marker)

    ctx.actions.run_shell(
        command = 'exec python3 "$@"',
        arguments = [args],
        inputs = [ctx.file.assets, ctx.file.native_libs, ctx.file._checker],
        outputs = [marker],
        env = FLUTTER_ENV,
        mnemonic = "NativeAssetsCheck",
        progress_message = "Checking Dart code assets %{label}",
    )

    return [DefaultInfo(files = depset([marker]))]

native_assets_check = rule(
    implementation = _native_assets_check_impl,
    doc = """Fails the build if a Dart code asset has no library behind it.

A package with a build hook declares an asset id; the Dart VM resolves it to a
filename through the bundle's NativeAssetsManifest.json and dlopens that name
from lib/<abi>/. Nothing else connects the two halves -- the manifest comes from
flutter_tools, the library only from a package recipe -- so a package with no
recipe builds green and dies on its first FFI call.

Cheap enough to depend on from the app; see //app:native_assets_check.""",
    attrs = {
        "assets": attr.label(
            allow_single_file = True,
            mandatory = True,
            doc = "A flutter_assets tree artifact.",
        ),
        "native_libs": attr.label(
            allow_single_file = True,
            mandatory = True,
            doc = "The jar of recipe-contributed libraries, @flutter_plugins//:native_libs_jar.",
        ),
        "_checker": attr.label(
            default = "//tools/flutter:check_native_assets.py",
            allow_single_file = True,
        ),
    },
)

def _jni_lib_jar_impl(ctx):
    jar = ctx.actions.declare_file(ctx.label.name + ".jar")

    # android_binary sources native libraries from cc_library deps, but it also
    # extracts lib/<abi>/*.so from jars on the classpath -- which is how the
    # prebuilt engine artifact (arm64_v8a_release.jar) ships libflutter.so.
    # Packaging libapp.so the same way avoids standing up an Android CC
    # toolchain just to carry one prebuilt shared object.
    ctx.actions.run_shell(
        command = """set -euo pipefail
STAGE="$(mktemp -d "${{TMPDIR:-/tmp}}/jnilib.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/lib/{abi}"
cp "{so}" "$STAGE/lib/{abi}/{soname}"
# -X drops extra attributes; entries are added in a fixed order so the jar is
# reproducible.
( cd "$STAGE" && zip -q -X -r "$OLDPWD/{jar}" lib )
""".format(
            abi = ctx.attr.abi,
            so = ctx.file.src.path,
            soname = ctx.attr.soname or ctx.file.src.basename,
            jar = jar.path,
        ),
        inputs = [ctx.file.src],
        outputs = [jar],
        mnemonic = "JniLibJar",
        progress_message = "Packaging %{label} for Android",
    )

    return [DefaultInfo(files = depset([jar]))]

jni_lib_jar = rule(
    implementation = _jni_lib_jar_impl,
    doc = "Wraps a prebuilt .so as lib/<abi>/<name>.so inside a jar, for android_binary.",
    attrs = {
        "src": attr.label(allow_single_file = True, mandatory = True),
        "abi": attr.string(default = "arm64-v8a"),
        "soname": attr.string(doc = "Override the packaged filename."),
    },
)

def _android_platform_transition_impl(_settings, attr):
    return {"//command_line_option:platforms": [attr.platform]}

# The .so has to be built for Android whatever configuration it is reached
# from. Without this, the cmake() target is analysed in the enclosing
# configuration -- the host, when it hangs off a java_import on an
# android_library -- and rules_foreign_cc resolves the *macOS* cc_toolchain,
# feeding host linker flags to an NDK cross-compile.
#
# Transitioning here rather than relying on android_binary's own native-dep
# transition keeps this self-contained: the jar is correct by construction, so
# nothing downstream has to be configured a particular way to make it so.
_android_platform_transition = transition(
    implementation = _android_platform_transition_impl,
    inputs = [],
    outputs = ["//command_line_option:platforms"],
)

def _android_native_lib_jar_impl(ctx):
    jar = ctx.actions.declare_file(ctx.label.name + ".jar")

    # cmake() reports its whole install tree (headers included); only the
    # shared objects belong in the jar.
    sos = [
        f
        for target in ctx.attr.src
        for f in target[DefaultInfo].files.to_list()
        if f.basename.endswith(".so")
    ]
    if not sos:
        fail("{} produced no .so -- check out_shared_libs on {}".format(
            ctx.label,
            ctx.attr.src[0].label,
        ))

    cc_toolchain = find_cpp_toolchain(ctx)

    # Same mechanism as jni_lib_jar: android_binary extracts lib/<abi>/*.so from
    # jars on the classpath, so a plugin's native library rides exactly the path
    # libapp.so and libflutter.so already ride.
    #
    # Stripped on the way in. A CMake plugin's .so keeps its symbol table under
    # the NDK's release flags -- rive_common's is 4.3 MB stripping to 3.5 MB --
    # so this is not an engine-only concern.
    ctx.actions.run_shell(
        command = """set -euo pipefail
STAGE="$(mktemp -d "${{TMPDIR:-/tmp}}/jnilib.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/lib/{abi}"
for so in {sos}; do
    cp "$so" "$STAGE/lib/{abi}/"
    "{strip}" --strip-unneeded "$STAGE/lib/{abi}/$(basename "$so")"
done
( cd "$STAGE" && zip -q -X -r "$OLDPWD/{jar}" lib )
""".format(
            abi = ctx.attr.abi,
            sos = " ".join(['"{}"'.format(f.path) for f in sos]),
            jar = jar.path,
            strip = cc_toolchain.strip_executable,
        ),
        inputs = depset(sos, transitive = [cc_toolchain.all_files]),
        outputs = [jar],
        mnemonic = "AndroidNativeLibJar",
        progress_message = "Packaging native libraries %{label} for Android",
    )

    return [DefaultInfo(files = depset([jar]))]

android_native_lib_jar = rule(
    implementation = _android_native_lib_jar_impl,
    doc = """Builds a native library for Android and wraps it as lib/<abi>/*.so in a jar.

`src` is built under `platform` regardless of the configuration this target is
reached from -- see _android_platform_transition.""",
    cfg = _android_platform_transition,
    attrs = {
        "src": attr.label_list(
            mandatory = True,
            doc = "Target producing .so files, typically a rules_foreign_cc cmake().",
        ),
        "abi": attr.string(default = "arm64-v8a"),
        "platform": attr.string(
            default = "@rules_android//:arm64-v8a",
            doc = "Platform the native library is built for.",
        ),
    },
    toolchains = use_cc_toolchain(),
)

def _strip_native_libs_impl(ctx):
    stripped = ctx.actions.declare_file(ctx.label.name + ".jar")

    # The NDK's llvm-strip, resolved through the Android cc_toolchain rather
    # than hardcoded: the rule transitions to the Android platform (below), so
    # this is the cross-strip that matches the .so being stripped.
    #
    # The transition is load-bearing and its absence is not obviously wrong.
    # Analysed without it, this resolves /opt/homebrew/opt/binutils/bin/strip --
    # a host tool that happens to handle ELF, so it would produce a plausible
    # artifact on a machine that has it and fall back to the macOS strip
    # (which cannot) on one that does not.
    cc_toolchain = find_cpp_toolchain(ctx)

    # AGP does this automatically for release builds (`stripDebugSymbolsRelease`);
    # android_binary has no equivalent, which is why the engine's 156 MB of DWARF
    # was reaching the APK.
    ctx.actions.run_shell(
        command = """set -euo pipefail
STAGE="$(mktemp -d "${{TMPDIR:-/tmp}}/strip.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
unzip -q -o "{jar}" -d "$STAGE"

found=0
for so in $(find "$STAGE" -type f -name '*.so' | sort); do
    found=1
    "{strip}" --strip-unneeded "$so"
done

if [ "$found" -eq 0 ]; then
    echo "strip_native_libs: no .so found in {jar}" >&2
    echo "The jar this rule was pointed at carries no native libraries;" >&2
    echo "stripping it silently would produce a correct-looking no-op." >&2
    exit 1
fi

( cd "$STAGE" && zip -q -X -r "$OLDPWD/{out}" . )
""".format(
            jar = ctx.file.jar.path,
            out = stripped.path,
            strip = cc_toolchain.strip_executable,
        ),
        inputs = depset([ctx.file.jar], transitive = [cc_toolchain.all_files]),
        outputs = [stripped],
        mnemonic = "StripNativeLibs",
        progress_message = "Stripping native libraries %{label}",
    )

    return [DefaultInfo(files = depset([stripped]))]

strip_native_libs = rule(
    implementation = _strip_native_libs_impl,
    doc = """Strips every .so inside a jar.

The stripped jar is the default output, so it drops straight into an
android_binary's classpath where the original jar was.""",
    cfg = _android_platform_transition,
    attrs = {
        "jar": attr.label(
            allow_single_file = [".jar"],
            mandatory = True,
            doc = "Jar carrying lib/<abi>/*.so -- e.g. the Flutter engine artifact.",
        ),
        "platform": attr.string(
            default = "@rules_android//:arm64-v8a",
            doc = "Platform whose cc_toolchain supplies strip.",
        ),
    },
    toolchains = use_cc_toolchain(),
)
