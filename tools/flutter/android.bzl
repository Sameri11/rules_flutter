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
load("@rules_android//rules:rules.bzl", "android_library")
load("@rules_cc//cc:find_cc_toolchain.bzl", "find_cpp_toolchain", "use_cc_toolchain")
load("@rules_java//java:defs.bzl", "java_import")
load(":bundle.bzl", "ASSETS", "CLASSES", "FlutterBundleContributionInfo", "NATIVE_LIB", "flutter_bundle_contribution")

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

# --- The join: seven named contributions, one target for android_binary -------

# Every contribution an Android APK needs, in the order VI.2's inventory lists
# them. A platform's join asserts it produced exactly this set, so adding a
# contribution to the concept is a change here rather than a silent omission in
# one consumer's BUILD file.
_ANDROID_CONTRIBUTIONS = [
    ("aot_library", NATIVE_LIB),
    ("engine", NATIVE_LIB),
    ("runtime_classes", CLASSES),
    ("assets", ASSETS),
    ("plugin_libraries", CLASSES),
    ("recipe_libraries", NATIVE_LIB),
    ("registrant", CLASSES),
]

def _flutter_bundle_check_impl(ctx):
    marker = ctx.actions.declare_file(ctx.label.name + ".checked")

    by_kind = {}
    for dep in ctx.attr.contributions:
        info = dep[FlutterBundleContributionInfo]
        if info.kind in by_kind:
            fail("Two contributions declare kind '{}'.".format(info.kind))
        by_kind[info.kind] = info

    # The completeness half. Today this only catches a join that forgot a
    # contribution; under multiple ABIs it is where "this ABI has no libapp.so"
    # goes -- see multi-abi.md section 9, which proposes the same target.
    for kind, _location in _ANDROID_CONTRIBUTIONS:
        if kind not in by_kind:
            fail(
                ("Bundle is missing the '{}' contribution.\n" +
                 "Every entry in _ANDROID_CONTRIBUTIONS must be supplied, or " +
                 "declared empty.").format(kind),
            )

    # The code-asset half, formerly //app:native_assets_check. It sits here
    # because this is the first place that can see *both* halves it compares:
    # the manifest inside the asset tree, and the libraries the recipes
    # supplied. As a standalone target it was something the app had to remember
    # to depend on.
    assets = by_kind["assets"].files.to_list()
    libs = by_kind["recipe_libraries"].files.to_list()
    if not assets:
        fail("The 'assets' contribution is empty; nothing to check code assets against.")

    args = ctx.actions.args()
    args.add(ctx.file._checker)

    # flutter_tools writes the manifest at the bundle root --
    # `additionalContent: {'NativeAssetsManifest.json': ...}` in
    # build_system/targets/common.dart. Derived rather than declared, because it
    # lives inside a tree artifact.
    args.add("--manifest", assets[0].path + "/NativeAssetsManifest.json")
    args.add("--jar", libs[0])
    args.add("--out", marker)

    ctx.actions.run_shell(
        command = 'exec python3 "$@"',
        arguments = [args],
        inputs = assets + libs + [ctx.file._checker],
        outputs = [marker],
        env = FLUTTER_ENV,
        mnemonic = "FlutterBundleCheck",
        progress_message = "Checking bundle contributions %{label}",
    )

    return [DefaultInfo(files = depset([marker]))]

flutter_bundle_check = rule(
    implementation = _flutter_bundle_check_impl,
    doc = """Fails the build if the bundle is missing a contribution, or a code asset has no library.

Instantiated by flutter_android_libs, not written by hand. Two checks: every
contribution in the inventory is present, and every Dart code asset the bundle
names resolves to a library some recipe supplied. The second was
`native_assets_check`; it moved here because this is where both halves are
visible at once.""",
    attrs = {
        "contributions": attr.label_list(
            providers = [FlutterBundleContributionInfo],
            mandatory = True,
        ),
        "_checker": attr.label(
            default = "//tools/flutter:check_native_assets.py",
            allow_single_file = True,
        ),
    },
)

# buildifier: disable=unnamed-macro
# Not a macro: it declares no target and returns a string. buildifier classifies
# it as one because it touches native.*, which a pure label computation has to.
def flutter_assets_dir(assets):
    """The `assets_dir` android_binary needs for a flutter_assets target.

    android_binary strips this prefix from each asset's path to get its location
    in the APK, so it has to match where the tree artifact actually sits. That
    makes it a per-consumer value -- `app/assets` here, `packages/smooth_app/assets`
    in the smooth_app consumer -- and getting it wrong is silent: the assets land
    at the wrong path, and the app builds, installs, launches and then fails to
    find its bundle at runtime.

    It is derivable rather than remembered. `flutter_assets` declares its tree as
    `<name>/flutter_assets`, so the prefix is always the target's package plus its
    name. Assumes the assets target is in the consumer's own workspace, which is
    the only place a project's own assets can be.

    Args:
      assets: the flutter_assets target's label, as written in the BUILD file.

    Returns:
      The string to pass as android_binary's assets_dir.
    """

    # package_relative_label, not Label: Label() resolves against *this file's*
    # package, so a caller writing ":assets" would get tools/flutter/assets.
    # Absolute labels hid that -- both real consumers happen to write one.
    label = native.package_relative_label(assets)

    # A target in the root package has an empty package, and "/assets" is not
    # the same path as "assets".
    if not label.package:
        return label.name
    return "{}/{}".format(label.package, label.name)

def flutter_android_libs(
        name,
        aot,
        assets,
        engine_jar,
        embedding,
        plugins,
        native_libs,
        registrant,
        embedding_deps = [],
        abi = "arm64-v8a",
        **kwargs):
    """Every Flutter contribution to an APK, joined into one android_binary dep.

    Before this existed the seven contributions were spelled out by hand in the
    consumer's `android_binary` deps, which meant nothing named the concept and
    a second platform meant a second hand-written assembly with the same chance
    of silently omitting a piece.

    `embedding` and `embedding_deps` are supplied by the caller rather than
    resolved here, and that is load bearing: they are Maven labels from the
    *consuming* project's resolution, and a bare label string written inside
    this module would resolve against this module's own Maven graph. See
    embedding.bzl.

    Args:
      name: the target android_binary depends on.
      aot: the AOT library, a dart_aot_elf / flutter_aot_library target.
      assets: a flutter_assets tree artifact.
      engine_jar: the prebuilt engine jar, unstripped.
      embedding: the consumer's flutter_embedding_library target.
      plugins: the generated aggregate of native plugin libraries.
      native_libs: the generated jar of recipe-contributed libraries.
      registrant: the native GeneratedPluginRegistrant library.
      embedding_deps: the embedding's Maven dependencies, from
        flutter_embedding_deps().
      abi: the ABI the native contributions are packaged under.
      **kwargs: visibility, tags.
    """

    # 1. AOT library. The snapshot rides as lib/<abi>/libapp.so inside a jar,
    #    because android_binary extracts native libraries from jars on the
    #    classpath -- the same mechanism the prebuilt engine artifact uses.
    jni_lib_jar(
        name = name + "_libapp_jni",
        src = aot,
        abi = abi,
        **kwargs
    )
    java_import(
        name = name + "_libapp",
        jars = [name + "_libapp_jni"],
        **kwargs
    )

    # 2. Engine. Ships from Maven with its DWARF intact, and android_binary has
    #    no equivalent of AGP's stripDebugSymbolsRelease.
    strip_native_libs(
        name = name + "_engine_stripped",
        jar = engine_jar,
        **kwargs
    )
    java_import(
        name = name + "_engine",
        jars = [name + "_engine_stripped"],
        **kwargs
    )

    sources = {
        "aot_library": [name + "_libapp_jni"],
        "engine": [name + "_engine_stripped"],
        "runtime_classes": [embedding],
        "assets": [assets],
        "plugin_libraries": [plugins],
        "recipe_libraries": [native_libs],
        "registrant": [registrant],
    }
    contributions = []
    for kind, location in _ANDROID_CONTRIBUTIONS:
        contribution = "{}_{}_contribution".format(name, kind)
        flutter_bundle_contribution(
            name = contribution,
            kind = kind,
            location = location,
            srcs = sources[kind],
            **kwargs
        )
        contributions.append(contribution)

    flutter_bundle_check(
        name = name + "_check",
        contributions = contributions,
        **kwargs
    )

    # The one target android_binary depends on. `exports` rather than `deps`:
    # Bazel does not re-export deps to a consumer's compile classpath, and the
    # registrant compiles against the embedding.
    #
    # The asset tree is deliberately *not* carried here, even though
    # android_library accepts `assets` and doing so would let android_binary
    # drop its own assets attribute. Measured: it makes this a resource-producing
    # target, which forces a package name and emits an R class -- 14 classes
    # (R plus its nested R$attr, R$string, ...) that land in the dex and are
    # never read. Every other one of the APK's 768 entries was byte-identical,
    # so that was the whole cost, and it is still a cost with no benefit: the
    # assets were never in `deps`, so routing them through here does not change
    # what the consumer writes. The contribution is still declared below, so the
    # bundle check sees the asset tree either way.
    android_library(
        name = name,
        # Order mirrors the deps list consumers wrote before this macro existed.
        # It has no semantic effect -- exports is a set as far as the compile
        # classpath is concerned -- but android_binary adds native libraries in
        # walk order, so it decides their position in the zip and therefore the
        # APK's alignment padding. Keeping it lets an APK hash comparison stay a
        # meaningful check on this rule.
        exports = [
            registrant,
            name + "_libapp",
            native_libs,
            name + "_engine",
            embedding,
        ] + embedding_deps + [plugins],
        **kwargs
    )
