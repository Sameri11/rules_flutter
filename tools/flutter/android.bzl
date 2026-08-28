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

load("@bazel_skylib//rules:build_test.bzl", "build_test")
load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("@rules_android//rules:rules.bzl", "android_binary", "android_library")
load("@rules_cc//cc:find_cc_toolchain.bzl", "find_cpp_toolchain", "use_cc_toolchain")
load("@rules_java//java:defs.bzl", "java_import")
load(":abis.bzl", "ABIS", "ABI_PLATFORM_ATTRS", "MIN_SDK", "check_abis", "check_platform_abi", "engine_jar_label", "plugin_repo_target")
load(":bundle.bzl", "ASSETS", "CLASSES", "FlutterBundleContributionInfo", "NATIVE_LIB", "flutter_bundle_contribution")
load(":embedding.bzl", "flutter_embedding_deps")
load(":pubspec.bzl", "FlutterPubspecInfo")

_MODE_DEBUG = Label("//tools/flutter:mode_debug")
_MODE_RELEASE = Label("//tools/flutter:mode_release")

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
        # Mandatory: it decides which lib/<abi>/ the library is loaded from, so
        # a default packages one architecture's .so as another's, silently.
        # This rule does not transition --platforms; its ambient platform is the
        # caller's, so check_platform_abi is not applicable.
        "abi": attr.string(mandatory = True),
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
    abi = check_platform_abi(ctx)

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
            abi = abi,
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

_android_native_lib_jar = rule(
    implementation = _android_native_lib_jar_impl,
    doc = """Builds a native library for Android and wraps it as lib/<abi>/*.so in a jar.

`src` is built under `platform` regardless of the configuration this target is
reached from -- see _android_platform_transition.""",
    cfg = _android_platform_transition,
    attrs = dict(
        ABI_PLATFORM_ATTRS,
        src = attr.label_list(
            mandatory = True,
            doc = "Target producing .so files, typically a rules_foreign_cc cmake().",
        ),
        abi = attr.string(mandatory = True),
        platform = attr.string(
            mandatory = True,
            doc = "Platform the native library is built for. Derived from `abi`.",
        ),
    ),
    toolchains = use_cc_toolchain(),
)

def android_native_lib_jar(name, src, abi, **kwargs):
    """Cross-compiles a native library for one ABI and jars it as lib/<abi>/.

    `abi` is mandatory and `platform` is derived from it. They used to be two
    strings a caller kept in step by hand: the jar's `lib/<abi>/` prefix decides
    where the library is *installed*, the platform decides which toolchain
    *builds* it, and a build where they disagree ships a working-looking APK
    that crashes on load.

    Args:
      name: the target name; its output is the jar.
      src: targets producing .so files, typically a cmake().
      abi: the Android ABI to build and package for.
      **kwargs: visibility, tags.
    """
    check_abis([abi], "android_native_lib_jar " + name)
    _android_native_lib_jar(
        name = name,
        src = src,
        abi = abi,
        platform = ABIS[abi].bazel_platform,
        **kwargs
    )

def _strip_native_libs_impl(ctx):
    check_platform_abi(ctx)

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
    # android_binary has no equivalent, which is why the engine's DWARF
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

_strip_native_libs = rule(
    implementation = _strip_native_libs_impl,
    doc = """Strips every .so inside a jar.

The stripped jar is the default output, so it drops straight into an
android_binary's classpath where the original jar was.""",
    cfg = _android_platform_transition,
    attrs = dict(
        ABI_PLATFORM_ATTRS,
        jar = attr.label(
            allow_single_file = [".jar"],
            mandatory = True,
            doc = "Jar carrying lib/<abi>/*.so -- e.g. the Flutter engine artifact.",
        ),
        # check_platform_abi validates the transitioned platform against `abi`.
        abi = attr.string(mandatory = True),
        platform = attr.string(
            mandatory = True,
            doc = "Platform whose cc_toolchain supplies strip. Derived from `abi`.",
        ),
    ),
    toolchains = use_cc_toolchain(),
)

def strip_native_libs(name, jar, abi, **kwargs):
    """Strips every .so inside a jar, with the ABI's own cross-strip.

    `platform` is derived rather than asked for: it selects the NDK toolchain
    that strips, so a platform naming one architecture while the jar carries
    another is a mismatch nothing downstream can see. One value, one place --
    the ABI table.

    Args:
      name: the target name; its output is the stripped jar.
      jar: a jar carrying lib/<abi>/*.so.
      abi: the ABI whose libraries the jar holds.
      **kwargs: visibility, tags.
    """
    check_abis([abi], "strip_native_libs " + name)
    _strip_native_libs(
        name = name,
        jar = jar,
        abi = abi,
        platform = ABIS[abi].bazel_platform,
        **kwargs
    )

def _flutter_android_manifest_impl(ctx):
    out = ctx.actions.declare_file(ctx.label.name + "/AndroidManifest.xml")

    args = ctx.actions.args()

    pubspec = ctx.attr.pubspec[FlutterPubspecInfo]

    args.add(ctx.file._injector)
    args.add("--version-name", pubspec.version_name)
    args.add("--version-code", pubspec.version_code)
    args.add("--manifest", ctx.file.manifest)
    args.add("--out", out)

    ctx.actions.run_shell(
        command = 'exec python3 "$@"',
        arguments = [args],
        inputs = [
            # The two version facts, not pubspec.yaml: an edit elsewhere in the
            # pubspec must not repackage the APK's resources.
            pubspec.version_name,
            pubspec.version_code,
            ctx.file.manifest,
            ctx.file._injector,
        ],
        outputs = [out],
        mnemonic = "FlutterAndroidManifest",
        progress_message = "Injecting pubspec version into AndroidManifest %{label}",
    )

    return [DefaultInfo(files = depset([out]))]

flutter_android_manifest = rule(
    implementation = _flutter_android_manifest_impl,
    doc = """An AndroidManifest carrying pubspec.yaml's version.

`versionCode` and `versionName` are the one pair of manifest values Bazel
cannot pass through `manifest_values`: that attribute is a load-time dict and
the version is in a file. An APK without a versionCode cannot be published, so
the value has to reach the manifest through an action.

The source manifest is otherwise copied verbatim -- one line differs -- so it
stays readable against the template `flutter create` generated.""",
    attrs = {
        "manifest": attr.label(
            allow_single_file = [".xml"],
            mandatory = True,
            doc = "The app's AndroidManifest.xml.",
        ),
        "pubspec": attr.label(
            mandatory = True,
            providers = [FlutterPubspecInfo],
            doc = "A flutter_pubspec target; supplies both version facts.",
        ),
        "_injector": attr.label(
            default = "//tools/flutter:inject_version.py",
            allow_single_file = True,
        ),
    },
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
    # The plugins' *native* half, named apart from their classes because the two
    # land in different places and only one of them varies by ABI. It packages
    # nothing -- the libraries already ride into the APK inside `plugin_libraries`
    # -- but under that kind they are jars of classes, where a per-ABI check
    # cannot see them, and a plugin missing for one ABI was silent.
    ("plugin_native_libraries", NATIVE_LIB),
    ("recipe_libraries", NATIVE_LIB),
    ("registrant", CLASSES),
]

def _contributions_for(mode):
    """The contribution inventory for one mode.

    A macro cannot compute this itself -- mode is a configuration value,
    invisible until a rule reads it -- so flutter_android_libs always declares
    the aot_library contribution and `select()`s it out of what it *wires in*
    for debug. This is what the checker expects to see once that selection has
    resolved, and the only place the two have to agree.

    `aot_library` is release-only: debug ships no AOT snapshot -- JIT compiles
    from kernel_blob.bin instead.
    """
    if mode == "debug":
        return [(kind, location) for kind, location in _ANDROID_CONTRIBUTIONS if kind != "aot_library"]
    return _ANDROID_CONTRIBUTIONS

def _libraries_required(mode):
    return ["engine"] if mode == "debug" else ["aot_library", "engine"]

def _flutter_bundle_check_impl(ctx):
    marker = ctx.actions.declare_file(ctx.label.name + ".checked")

    check_abis(ctx.attr.abis, str(ctx.label))
    mode = ctx.attr._mode[BuildSettingInfo].value
    expected = _contributions_for(mode)

    by_kind = {}
    for dep in ctx.attr.contributions:
        info = dep[FlutterBundleContributionInfo]
        if info.kind in by_kind:
            fail("Two contributions declare kind '{}'.".format(info.kind))
        by_kind[info.kind] = info

    # The completeness half, in two parts: every contribution is present, and
    # every native one covers every ABI -- an ABI with no libapp.so, or a
    # library forgotten for one of them, fails here rather than on a device.
    for kind, location in expected:
        if kind not in by_kind:
            fail(
                ("Bundle is missing the '{}' contribution for mode '{}'.\n" +
                 "Every entry _contributions_for(mode) names must be supplied, " +
                 "or declared empty.").format(kind, mode),
            )

        info = by_kind[kind]
        if location != NATIVE_LIB or info.empty:
            continue

        missing = [abi for abi in ctx.attr.abis if abi not in info.libraries]
        if missing:
            fail(
                ("The '{}' contribution has nothing for {}.\n" +
                 "This bundle declares abis = {}, and every native " +
                 "contribution must supply a library for each of them. It has " +
                 "{}.").format(
                    kind,
                    ", ".join(missing),
                    ctx.attr.abis,
                    sorted(info.libraries) if info.libraries else "(nothing)",
                ),
            )

        # The converse: a contribution carrying an ABI nobody asked for is a
        # fat APK arrived at by accident rather than declared.
        extra = [s for s in sorted(info.libraries) if s not in ctx.attr.abis]
        if extra:
            fail(
                ("The '{}' contribution supplies {}, which this bundle does " +
                 "not declare.\nabis = {}; drop the extra slice or add the ABI " +
                 "everywhere it belongs.").format(
                    kind,
                    ", ".join(extra),
                    ctx.attr.abis,
                ),
            )

    # The code-asset half, formerly //app:native_assets_check. It sits here
    # because this is the first place that can see *both* halves it compares:
    # the manifest inside the asset tree, and the libraries the recipes
    # supplied. As a standalone target it was something the app had to remember
    # to depend on.
    assets = by_kind["assets"].files.to_list()
    if not assets:
        fail("The 'assets' contribution is empty; nothing to check code assets against.")

    args = ctx.actions.args()
    args.add(ctx.file._checker)

    # flutter_tools writes the manifest at the bundle root --
    # `additionalContent: {'NativeAssetsManifest.json': ...}` in
    # build_system/targets/common.dart. Derived rather than declared, because it
    # lives inside a tree artifact.
    args.add("--manifest", assets[0].path + "/NativeAssetsManifest.json")
    args.add("--out", marker)
    args.add_all(_libraries_required(mode), before_each = "--require")

    inputs = list(assets) + [ctx.file._checker]

    for abi in ctx.attr.abis:
        # The key is the engine's, not ours -- each has the one it reads
        # compiled in.
        args.add("--abi", "{}={}".format(abi, ABIS[abi].manifest_key))

        for kind, location in expected:
            if location != NATIVE_LIB:
                continue
            jars = [
                f
                for f in by_kind[kind].libraries.get(abi, depset()).to_list()
                if f.extension == "jar"
            ]
            for jar in jars:
                args.add("--jar", "{}={}={}".format(abi, kind, jar.path))
            inputs += jars

    ctx.actions.run_shell(
        command = 'exec python3 "$@"',
        arguments = [args],
        inputs = inputs,
        outputs = [marker],
        mnemonic = "FlutterBundleCheck",
        progress_message = "Checking bundle contributions %{label}",
    )

    return [DefaultInfo(files = depset([marker]))]

flutter_bundle_check = rule(
    implementation = _flutter_bundle_check_impl,
    doc = """Fails the build if the bundle is missing a piece for any ABI it declares.

Instantiated by flutter_android_libs, not written by hand. Three checks, in
increasing depth: every contribution in the inventory is present; every native
contribution supplies a library for every declared ABI and no other; and, at
action time, each of those libraries really sits under lib/<abi>/ and backs the
code assets the manifest names for that ABI.

The last two are one guard split across phases, because analysis sees only that
a label was supplied. Handing the arm64 jar to the x86_64 slot resolves, builds,
and ships an empty ABI.""",
    attrs = {
        "abis": attr.string_list(
            mandatory = True,
            doc = "The ABIs the bundle claims to support. Every native contribution must cover each.",
        ),
        "contributions": attr.label_list(
            providers = [FlutterBundleContributionInfo],
            mandatory = True,
        ),
        "_checker": attr.label(
            default = "//tools/flutter:check_native_assets.py",
            allow_single_file = True,
        ),
        "_mode": attr.label(
            default = "//tools/flutter:mode",
            providers = [BuildSettingInfo],
        ),
    },
)

# buildifier: disable=unnamed-macro
# Not a macro: it declares no target and returns a string. buildifier classifies
# it as one because it touches native.*, which a pure label computation has to.
def flutter_assets_dir(assets):
    """The `assets_dir` android_binary needs for a flutter_assets target.

    android_binary strips this prefix from each generated asset `File.path` to
    get its location in the APK, so it has to match where the tree artifact
    actually sits. That makes it a per-consumer value -- `app/assets` here,
    `packages/smooth_app/assets` in the smooth_app consumer -- and getting it
    wrong is silent: the assets land at the wrong path, and the app builds,
    installs, launches and then fails to find its bundle at runtime.

    It is derivable rather than remembered. `flutter_assets` declares its tree as
    `<name>/flutter_assets`, so the prefix is always the target's workspace
    root, package, and name. `Label.workspace_root` is required because
    rules_android partitions generated asset `File.path` values by `assets_dir`.

    Args:
      assets: the flutter_assets target's label, as written in the BUILD file.

    Returns:
      The string to pass as android_binary's assets_dir.
    """

    # package_relative_label, not Label: Label() resolves against *this file's*
    # package, so a caller writing ":assets" would get tools/flutter/assets.
    # Absolute labels hid that -- both real consumers happen to write one.
    label = native.package_relative_label(assets)

    return "/".join([
        component
        for component in [label.workspace_root, label.package, label.name]
        if component
    ])

# The repository these rules generate for a project's plugins. Its name is
# hardcoded by the extension (plugins.bzl), and every consumer imports it under
# that apparent name -- they have to, because they name `@flutter_plugins//:all`
# themselves. A string handed to an attribute from inside a macro resolves in
# the *caller's* repo mapping, so emitting these labels here resolves to the
# consuming project's plugin set, not ours. That is what makes them derivable;
# the engine repos are not, which is why engine_jar_label returns a Label.
_PLUGIN_REPO = "@flutter_plugins"

def _plugin_libs(kind, abis):
    """`@flutter_plugins//:<target>` per ABI, for one contribution kind.

    plugins.bzl emits one such target per ABI in `plugins.project(abis)`, and
    names it through the same `plugin_repo_target` helper, so the dict a consumer
    used to write out is a function of `abis` alone and the two files cannot
    drift apart on the spelling.

    Args:
      kind: the contribution kind -- `recipe_libraries` or
        `plugin_native_libraries`.
      abis: the ABIs to name.

    Returns:
      ABI -> label string.
    """
    return {
        abi: "{}//:{}".format(_PLUGIN_REPO, plugin_repo_target(kind, abi))
        for abi in abis
    }

def _per_abi(supplied, abis, kind):
    """One variant's slice of a library dict, derived if the caller named none.

    Args:
      supplied: the caller's ABI -> label dict, or None to derive it.
      abis: the ABIs this variant ships.
      kind: the @flutter_plugins target-name prefix to derive from.

    Returns:
      ABI -> label, restricted to `abis`.
    """
    if supplied == None:
        return _plugin_libs(kind, abis)
    return {abi: supplied[abi] for abi in abis if abi in supplied}

def flutter_android_libs(
        name,
        abis,
        aot,
        assets,
        embedding = ":flutter_embedding",
        plugins = _PLUGIN_REPO + "//:all",
        native_libs = None,
        registrant = None,
        plugin_native_libs = None,
        embedding_deps = None,
        maven_repo = "@flutter_maven",
        engine_jars = {},
        **kwargs):
    """Every Flutter contribution to an APK, joined into one android_binary dep.

    Before this existed the seven contributions were spelled out by hand in the
    consumer's `android_binary` deps, which meant nothing named the concept and
    a second platform meant a second hand-written assembly with the same chance
    of silently omitting a piece.

    `abis` is required and always a list, as it is everywhere else. Everything
    that is a function of it is derived: the snapshot is `<aot>_<abi>`, the
    engine comes from the ABI table, and the plugin and recipe library jars are
    `@flutter_plugins//:{native_libs,plugin_libs}_<abi>` -- names these rules
    generate, so a consumer restating them could only ever restate them
    identically or wrongly.

    `embedding` and `embedding_deps` default to what both real consumers write,
    and that default is a *relative* label plus a helper call: the `java_import`
    itself still has to live in the consumer's package, because its deps come
    from the consuming project's Maven resolution. See embedding.bzl.

    Args:
      name: the target android_binary depends on.
      abis: the Android ABIs this APK ships. Required, always a list.
      aot: the flutter_aot_library *prefix*; `<aot>_<abi>` is used per ABI.
      assets: a flutter_assets tree artifact, built for at least these ABIs.
      embedding: the consumer's flutter_embedding_library target.
      plugins: the generated aggregate of native plugin libraries.
        `None` is the explicit no-plugin-graph shape: recipe/plugin library
        dicts default to `{}`, the registrant defaults to absent, and all four
        corresponding bundle contributions are declared empty. It creates no
        `@flutter_plugins` label.
      native_libs: ABI -> the jar of recipe-contributed libraries for it.
        Derived from `abis` when a plugin graph exists; `{}` when `plugins` is
        None. Pass `{}` explicitly to declare no package recipes while retaining
        a plugin graph.
      registrant: the native GeneratedPluginRegistrant library. Defaults to
        `:generated_plugin_registrant` when `plugins` is not None, and absent in
        the no-plugin shape.
      plugin_native_libs: ABI -> the jars the native plugins built for it.
        Derived from `abis` when a plugin graph exists; pass `{}` to say no
        plugin in this app has a native half.
      embedding_deps: the embedding's Maven dependencies. Defaults to
        flutter_embedding_deps(maven_repo).
      maven_repo: the repository the consumer's Maven coordinates resolve in --
        the one `flutter_embedding_library` was given. Only read to derive
        `embedding_deps`, and it has to match: a default naming one repository
        while the embedding target names another puts two Maven graphs on the
        classpath.
      engine_jars: ABI -> an unstripped engine jar, overriding the one the ABI
        table names. For a locally built engine; normally omitted.
      Under `mode=debug` the `aot_library` contribution and its `_libapp`
        export are dropped: debug ships no AOT snapshot, so nothing supplies
        one and android_binary must not expect it.
      **kwargs: visibility, tags.
    """
    no_plugin_graph = plugins == None
    if native_libs == None:
        native_libs = {} if no_plugin_graph else _plugin_libs("recipe_libraries", abis)
    if plugin_native_libs == None:
        plugin_native_libs = {} if no_plugin_graph else _plugin_libs("plugin_native_libraries", abis)
    if registrant == None and not no_plugin_graph:
        registrant = ":generated_plugin_registrant"
    if embedding_deps == None:
        embedding_deps = flutter_embedding_deps(maven_repo)

    check_abis(abis, "flutter_android_libs " + name)

    # A non-empty dict has to cover the declared ABI set exactly. `{}` is the
    # deliberate declaration that this app has no recipe or plugin-native
    # libraries; defaults only reach it in the explicit no-plugin shape.
    for what, supplied, required in [
        ("native_libs", native_libs, False),
        ("plugin_native_libs", plugin_native_libs, False),
        ("engine_jars", engine_jars, False),
    ]:
        if not required and not supplied:
            continue
        wrong = [abi for abi in abis if abi not in supplied] + [
            abi
            for abi in sorted(supplied)
            if abi not in abis
        ]
        if wrong:
            fail(
                ("flutter_android_libs {}: `{}` must have exactly one entry " +
                 "per declared ABI.\nabis = {}, but {} = {}.").format(
                    name,
                    what,
                    abis,
                    what,
                    sorted(supplied),
                ),
            )

    # One jar cannot serve two ABIs: its lib/<abi>/ prefix decides where the
    # libraries land, so the second ABI ships nothing. Checked across the
    # library dicts together rather than one at a time, because they share
    # `exports` below -- where the same mistake surfaces only as a duplicate
    # label, naming neither the ABI nor the reason.
    seen = {}
    for what, supplied in [
        ("native_libs", native_libs),
        ("plugin_native_libs", plugin_native_libs),
        ("engine_jars", engine_jars),
    ]:
        for abi in abis:
            if abi not in supplied:
                continue
            other = seen.get(str(supplied[abi]))
            if other:
                fail(
                    ("flutter_android_libs {}: `{}` for {} and {} are the same " +
                     "jar,\n  {}\nand a jar carries its ABI in the lib/<abi>/ " +
                     "prefix inside it. One of the two would ship nothing.").format(
                        name,
                        what,
                        abi,
                        other,
                        supplied[abi],
                    ),
                )
            seen[str(supplied[abi])] = "{} for {}".format(what, abi)

    # 1. AOT library. The snapshot rides as lib/<abi>/libapp.so inside a jar,
    #    because android_binary extracts native libraries from jars on the
    #    classpath -- the same mechanism the prebuilt engine artifact uses.
    #
    # 2. Engine. Ships from Maven with its DWARF intact, and android_binary has
    #    no equivalent of AGP's stripDebugSymbolsRelease. The strip is a
    #    cross-strip, so the ABI's own platform selects the NDK toolchain.
    libapp_jars = {}
    engine_stripped = {}
    for abi in abis:
        libapp_jars[abi] = "{}_libapp_{}_jni".format(name, abi)
        jni_lib_jar(
            name = libapp_jars[abi],
            src = "{}_{}".format(aot, abi),
            abi = abi,
            **kwargs
        )

        engine_stripped[abi] = "{}_engine_{}_stripped".format(name, abi)
        strip_native_libs(
            name = engine_stripped[abi],
            jar = engine_jars.get(abi, select({
                _MODE_DEBUG: engine_jar_label(abi, "debug"),
                _MODE_RELEASE: engine_jar_label(abi, "release"),
            })),
            abi = abi,
            **kwargs
        )

    # One java_import per contribution, not per ABI: android_binary collects
    # native libraries by walking the classpath, so the number of imports and
    # their order decide where each .so lands in the zip.
    java_import(
        name = name + "_libapp",
        jars = [libapp_jars[abi] for abi in abis],
        **kwargs
    )
    java_import(
        name = name + "_engine",
        jars = [engine_stripped[abi] for abi in abis],
        **kwargs
    )

    # Which contributions vary by ABI is the location's property, not a second
    # list to keep in step.
    slices = {
        "aot_library": libapp_jars,
        "engine": engine_stripped,
        "recipe_libraries": {
            abi: native_libs[abi]
            for abi in abis
            if abi in native_libs
        },
        "plugin_native_libraries": {
            abi: plugin_native_libs[abi]
            for abi in abis
            if abi in plugin_native_libs
        },
    }
    sources = {
        "runtime_classes": [embedding],
        "assets": [assets],
        "plugin_libraries": [plugins] if plugins else [],
        "registrant": [registrant] if registrant else [],
    }
    empty_kinds = [
        "plugin_libraries",
        "plugin_native_libraries",
        "recipe_libraries",
        "registrant",
    ]
    contributions = []
    aot_contribution = None
    for kind, location in _ANDROID_CONTRIBUTIONS:
        contribution = "{}_{}_contribution".format(name, kind)
        srcs = sources.get(kind, [])
        libraries = slices.get(kind, {})
        flutter_bundle_contribution(
            name = contribution,
            kind = kind,
            location = location,
            srcs = srcs,
            libraries = libraries,
            # These four contributions may genuinely be absent. Declaring
            # emptiness is still explicit at this boundary; the two structural
            # runtime contributions and the asset/AOT/engine never are.
            empty = kind in empty_kinds and not srcs and not libraries,
            **kwargs
        )
        if kind == "aot_library":
            # Declare AOT for all modes; debug excludes it before inputs are needed.
            aot_contribution = contribution
        else:
            contributions.append(contribution)

    flutter_bundle_check(
        name = name + "_check",
        abis = abis,
        contributions = contributions + select({
            _MODE_DEBUG: [],
            _MODE_RELEASE: [aot_contribution],
        }),
        **kwargs
    )

    # The one target android_binary depends on. `exports` rather than `deps`:
    # Bazel does not re-export deps to a consumer's compile classpath, and the
    # registrant compiles against the embedding.
    #
    # The asset tree is deliberately not carried here. android_library accepts
    # it, but that makes this a resource-producing target, which emits an R
    # class nothing reads. Assets were never in `deps` anyway, so routing them
    # through would not shorten what the consumer writes. The contribution is
    # still declared, so the bundle check sees the tree either way.
    android_library(
        name = name,
        # Order mirrors the deps list consumers wrote before this macro
        # existed. It means nothing to the compile classpath, but android_binary
        # adds native libraries in walk order, so it decides their position in
        # the zip and the alignment padding around them. Keeping it lets an APK
        # hash comparison stay a meaningful check on this rule.
        #
        # `:flutter_embedding` already re-exports these labels (embedding.bzl
        # sets `exports = deps`), so `embedding_deps` here is a second listing.
        # It is not redundant in the artifact: dropping it moved the demo fat
        # APK from f478aa57 to a7ed742f, because embedding_deps names
        # aar_import targets (e.g. androidx.fragment:fragment), and
        # java_import -- what :flutter_embedding is -- does not forward an
        # AAR's manifest/resource-merger providers the way a direct exports
        # edge from an android_library does. Measured on demo_app: dropping
        # this listing shrank AndroidManifest.xml (7,840 -> 7,268 bytes) and
        # resources.arsc (59,332 -> 56,276 bytes), dropped 7 androidx.fragment
        # animator resources (res/animator/fragment_*, res/anim-v21/
        # fragment_fast_out_extra_slow_in.xml), and shifted classes.dex
        # (6,960,492 -> 6,970,824 bytes; class_defs_size 4872 -> 4870,
        # method_ids_size 38420 -> 38476). Kept until a packaging change is
        # being rebaselined anyway. Full measurement, and a dex-size residual
        # this account doesn't explain, in
        # docs_internal/embedding-deps-findings.md -- open, flagged for round 5.
        exports = ([registrant] if registrant else []) + select({
            _MODE_DEBUG: [],
            _MODE_RELEASE: [name + "_libapp"],
        }) + [native_libs[abi] for abi in abis if abi in native_libs] + [
            plugin_native_libs[abi]
            for abi in abis
            if abi in plugin_native_libs
        ] + [
            name + "_engine",
            embedding,
        ] + embedding_deps + ([plugins] if plugins else []),
        **kwargs
    )

# Values AGP would supply from build.gradle.kts, which the manifest itself does
# not carry: ${applicationName} is a placeholder, and the SDK levels live in the
# gradle `minSdk` / `targetSdk`. targetSdk 36 is what flutter_tools pins
# (FlutterExtension.kt) and what enables edge-to-edge on Android 15+.
# `applicationId` is deliberately absent: it is the one value here that no file
# these rules read can supply, so it stays the consumer's to state.
#
# `minSdkVersion` is `MIN_SDK`, the same constant a plugin's CMake build targets
# as ANDROID_PLATFORM -- one value, one place. **It is not what the APK finally
# declares:** rules_android runs a min-SDK floor during resource processing
# (`bump_min_sdk`, 23 today) and clamps `manifest_values` against it, so both
# consumers ship 23 whatever is written here. Verified with `aapt2 dump badging`.
# The floor also blocks the dangerous direction -- a consumer asking for
# something *below* what the shipped `.so` files were linked against.
_MANIFEST_VALUES = {
    "applicationName": "io.flutter.app.FlutterApplication",
    "minSdkVersion": str(MIN_SDK),
    "targetSdkVersion": "36",
}

def flutter_android_binary(
        name,
        abis,
        app = None,
        manifest_values = {},
        deps = [],
        aot = None,
        assets = None,
        pubspec = None,
        manifest = "src/main/AndroidManifest.xml",
        debug_manifest = "src/debug/AndroidManifest.xml",
        resource_files = None,
        embedding = ":flutter_embedding",
        plugins = _PLUGIN_REPO + "//:all",
        native_libs = None,
        registrant = None,
        plugin_native_libs = None,
        embedding_deps = None,
        maven_repo = "@flutter_maven",
        engine_jars = {},
        **kwargs):
    """A fat APK and one per ABI, from a single declaration.

    Emits `<name>` carrying every ABI in `abis`, and `<name>_<abi>` carrying one
    -- so a developer can build the ABI their device takes while CI builds the
    APK that ships, out of the same targets:

        bazel build //app/android/app:demo_app                # fat
        bazel build //app/android/app:demo_app_arm64-v8a      # one ABI
        bazel build //app/android/app:demo_app{,_x86_64}      # both, one command

    Every variant shares its upstream actions: one kernel, one asset tree, one
    cross-compile per ABI. A second APK costs a second packaging step, not a
    second build of anything that goes into it.

    **The per-ABI variants are emitted only when `abis` names more than one.**
    For a single-ABI app `<name>` already is that ABI, and a `<name>_<abi>`
    beside it would package identical bytes a second time.

    A standard-layout app declares four things: `name`, `abis`, `app` and its
    `applicationId`. Everything else has a default that is either the created
    layout (`src/main/AndroidManifest.xml`, `src/main/res/**`) or a name these
    rules themselves generate:

        flutter_android_binary(
            name = "demo_app",
            abis = ["arm64-v8a"],
            app = "//app",
            manifest_values = {"applicationId": "com.example.demo_app"},
            deps = [":main_activity"],
        )

    `app` names the Bazel package holding the Dart half -- the package
    `flutter_app()` was called in -- and `aot`, `assets` and `pubspec` are its
    three conventional targets. Only its package part is read, so `//app` and
    `//app:app` mean the same thing. Any of the three can still be named
    directly, which is what an app whose Dart half is not laid out that way
    does.

    `assets_dir` is derived from `assets` rather than asked for: it has to agree
    with where the asset tree sits, and getting it wrong puts the bundle at a
    path the app only fails to find at runtime. See flutter_assets_dir.

    Args:
      name: the fat APK's target name.
      abis: the Android ABIs this app supports. Required, always a list.
      app: the package holding the Dart half, e.g. `//app`. `aot`, `assets` and
        `pubspec` are derived from it unless given.
      manifest_values: values the manifest does not carry. `applicationId` is
        required; `applicationName`, `minSdkVersion` and `targetSdkVersion`
        default to what flutter_tools pins and are overridable.
      deps: the app's own targets -- the activity, anything else it compiles.
        The Flutter join is appended, so ordering matches what a hand-written
        android_binary had.
      aot: the flutter_aot_library prefix; see flutter_android_libs.
      assets: a flutter_assets tree artifact.
      pubspec: the app's flutter_pubspec target, whose `version:` becomes
        versionCode and versionName. Required -- an APK with neither cannot be
        published, and a default of "unset" is how one gets shipped by accident.
      manifest: the app's AndroidManifest.xml.
      debug_manifest: a debug-only manifest merged in under `mode=debug` --
        `flutter create` generates one declaring INTERNET, for the tooling to
        reach a running debug app. Globbed rather than required, so a project
        (or test fixture) without one still loads; pass `None` to opt out.
      resource_files: the app's resources. Omit it only for a standard layout
        with a nonempty `src/main/res/**`; pass `[]` to declare a resource-free
        app explicitly.
      embedding: the consumer's flutter_embedding_library target.
      plugins: the generated aggregate of native plugin libraries. Pass `None`
        for a project with no `plugins.project()` / `@flutter_plugins`; all
        plugin, recipe and registrant contributions then default empty without
        creating a label into that repository.
      native_libs: ABI -> the recipe-contributed jar for it. Derived from `abis`
        with a plugin graph, `{}` without one.
      registrant: the native GeneratedPluginRegistrant library. Derived with a
        plugin graph, absent without one.
      plugin_native_libs: ABI -> the jars the native plugins built for it.
        Derived from `abis`; `{}` says no plugin here has a native half.
      embedding_deps: the embedding's Maven dependencies. Defaults to
        flutter_embedding_deps(maven_repo).
      maven_repo: the repository the embedding's Maven deps resolve in; must
        match what `flutter_embedding_library` was given.
      engine_jars: ABI -> an engine jar overriding the ABI table's.
      **kwargs: passed to every android_binary this declares -- visibility,
        tags, and anything else android_binary accepts. The emitted
        `<name>_check_test` takes only visibility and tags.
    """
    check_abis(abis, "flutter_android_binary " + name)

    if app:
        # `same_package_label`, not a rebuilt string: it keeps the *repository*
        # as well as the package, so `@other//app` derives `@other//app:app`
        # rather than silently retargeting the caller's own `//app`. `//app` and
        # `//app:app` name the same Dart half either way -- only the package part
        # is read.
        dart_half = native.package_relative_label(app)
        aot = aot or dart_half.same_package_label("app")
        assets = assets or dart_half.same_package_label("assets")
        pubspec = pubspec or dart_half.same_package_label("pubspec")

    missing = [
        what
        for what, value in [("aot", aot), ("assets", assets), ("pubspec", pubspec)]
        if not value
    ]
    if missing:
        fail(
            ("flutter_android_binary {}: name `app` -- the package holding the " +
             "Dart half -- or each of {} directly.").format(name, missing),
        )

    values = dict(_MANIFEST_VALUES)
    values.update(manifest_values)
    if "applicationId" not in values:
        fail(
            ("flutter_android_binary {}: manifest_values must set " +
             "`applicationId`. It is the package name the manifest's relative " +
             "class names resolve against, and nothing here can infer it -- " +
             "AGP takes it from build.gradle.kts.").format(name),
        )

    # aapt takes these two from `manifest_values` in preference to the manifest,
    # silently. Two sources for one value is the failure this whole file is
    # arranged against, so the collision is refused here rather than resolved.
    for key in ("versionCode", "versionName"):
        if key in values:
            fail(
                "flutter_android_binary {}: manifest_values['{}'] and ".format(name, key) +
                "`pubspec` both set the version, and manifest_values wins " +
                "Drop one.",
            )

    # One manifest for every variant: the version does not vary by ABI.
    versioned_manifest = name + "_manifest"
    flutter_android_manifest(
        name = versioned_manifest,
        manifest = manifest,
        pubspec = pubspec,
    )

    if resource_files == None:
        resource_files = native.glob(["src/main/res/**"], allow_empty = False)

    # Merge an optional debug manifest only in debug mode.
    debug_manifest_deps = []
    if debug_manifest:
        debug_manifest_files = native.glob([debug_manifest], allow_empty = True)
        if debug_manifest_files:
            debug_manifest_lib = name + "_debug_manifest"
            android_library(
                name = debug_manifest_lib,
                manifest = debug_manifest,
                exports_manifest = True,
                # Android manifest merging requires a package.
                custom_package = values["applicationId"],
                resource_files = [],
            )
            debug_manifest_deps = select({
                _MODE_DEBUG: [":" + debug_manifest_lib],
                _MODE_RELEASE: [],
            })

    # `plugins = None` is the complete no-plugin-graph declaration. Normalize
    # every default before per-ABI slicing so no helper constructs even one
    # @flutter_plugins label. A caller may still supply recipe libraries or a
    # custom registrant explicitly; only omitted pieces become empty.
    if plugins == None:
        if native_libs == None:
            native_libs = {}
        if plugin_native_libs == None:
            plugin_native_libs = {}
    elif registrant == None:
        registrant = ":generated_plugin_registrant"

    # Every library dict is keyed by ABI, and `abis` is the declared set. A key
    # outside it is dropped by the per-variant slicing below -- which is how a
    # dict naming *none* of the declared ABIs came to mean "no libraries at all"
    # instead of "misspelled ABI". Checked here because this is the only place
    # that sees a caller's whole dict before it is sliced; the exact per-ABI
    # coverage of what survives is flutter_android_libs' check.
    for what, supplied in [
        ("native_libs", native_libs),
        ("plugin_native_libs", plugin_native_libs),
        ("engine_jars", engine_jars),
    ]:
        if not supplied:
            continue
        unknown = [abi for abi in sorted(supplied) if abi not in abis]
        if unknown:
            fail(
                ("flutter_android_binary {}: `{}` names {}, which this APK " +
                 "does not declare.\nabis = {}. An entry outside that list is " +
                 "dropped, and the contribution ships empty.").format(
                    name,
                    what,
                    unknown,
                    abis,
                ),
            )

    variants = [(name, abis)]
    if len(abis) > 1:
        variants += [("{}_{}".format(name, abi), [abi]) for abi in abis]

    for target, target_abis in variants:
        join = target + "_flutter"
        flutter_android_libs(
            name = join,
            abis = target_abis,
            aot = aot,
            assets = assets,
            embedding = embedding,
            embedding_deps = embedding_deps,
            engine_jars = {
                abi: jar
                for abi, jar in engine_jars.items()
                if abi in target_abis
            },
            native_libs = _per_abi(native_libs, target_abis, "recipe_libraries"),
            plugin_native_libs = _per_abi(
                plugin_native_libs,
                target_abis,
                "plugin_native_libraries",
            ),
            plugins = plugins,
            registrant = registrant,
            maven_repo = maven_repo,
        )

        android_binary(
            name = target,
            assets = [assets],
            assets_dir = flutter_assets_dir(assets = assets),
            manifest = ":" + versioned_manifest,
            manifest_values = values,
            resource_files = resource_files,
            deps = deps + [":" + join] + debug_manifest_deps,
            **kwargs
        )

    # The bundle check per shape, under `bazel test`. It fails as an action, so
    # anything depending on it fails too -- but nothing does: the APK
    # deliberately does not, so that a missing contribution is reported by name
    # rather than as a packaging error. That is exactly the kind of check that
    # stops running unless something names it, so this names it.
    build_test(
        name = name + "_check_test",
        targets = [":{}_flutter_check".format(target) for target, _ in variants],
        # Not `**kwargs`: those are android_binary's attributes, and splatting
        # them here turned `flutter_android_binary(dexopts = ...)` into
        # `no such attribute 'dexopts' in '_empty_test' rule`. `visibility`
        # defaults to `None`, which a native attribute treats as unset -- but
        # `tags` cannot: build_test (a bazel_skylib macro, not a rule) does
        # `genrule_tags = kwargs.pop("tags", [])` and then `"manual" not in
        # genrule_tags`, so a literal `None` fails that check instead of
        # falling back to its own default.
        tags = kwargs.get("tags", []),
        visibility = kwargs.get("visibility"),
    )
