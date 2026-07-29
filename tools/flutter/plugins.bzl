"""Bazel targets for the Android half of Flutter plugins.

A Flutter plugin is a pub package that also ships a complete AGP library module
under `<package>/android/` -- its own manifest, sources, resources and Maven
dependencies. Gradle picks these up in `FlutterAppPluginLoaderPlugin`, which
reads `.flutter-plugins-dependencies` and `include`s each plugin's `android/`
directory as a subproject, then attaches it to the app as a `<buildType>Api`
dependency.

This does the same from the same input file: read the metadata, stage each
plugin's package root into an external repository, and generate one target per
plugin. A plugin whose `build.gradle` drives CMake also gets its `CMakeLists`
built with the NDK, and the resulting `.so` attached to the same label.

Three properties are deliberate, because they are what makes the gate in
`_GATED_REASONS` reversible rather than permanent:

  1. **The strategy is not in the label.** `@flutter_plugins//<name>` is the
     label whether the plugin was built from source alone, from source plus
     CMake, or by a recipe the consuming project supplied. Moving a plugin
     between them is a change here or in a recipe, never in a consumer.

  2. **Plugins are classified by *reason*, not by decision.** A plugin carries
     reason codes like `ndk_build`; routing is a single lookup against
     `_GATED_REASONS`. When a reason becomes supported, deleting its entry from
     that list re-routes every plugin carrying it at once -- which is exactly
     how `external_native_build` stopped being gated.

  3. **A package the generator cannot describe can be described by its user.**
     `plugins.package(bzl_file =, macro =)` names a macro in the consuming
     project; the BUILD generated for that package does nothing but load it by
     canonical label and hand over the facts. Because the load is canonical, the
     recipe's own `load()` statements resolve in *that project's* repo mapping,
     so a recipe may use rulesets this module has never heard of. This is also
     the per-package reversal of the gate: a reason stays gated for every package
     that has not been given an answer. See docs_internal/package-recipes.md.

     The registry is keyed on **pub package, not plugin**, because the packages
     that need it most are not always plugins -- `sqlite3` ships a Dart build
     hook and no `android/` module, so it appears nowhere in
     `.flutter-plugins-dependencies` and is resolved through
     `package_config.json` instead.
"""

load(":embedding.bzl", "FLUTTER_EMBEDDING_ARTIFACTS")
load(":maven.bzl", "highest_versions", "maven_label")

# Reason codes a plugin can carry. A plugin with none is built from source.
#
#   external_native_build  build.gradle drives CMake/ndk-build. CMake is now
#                          built (see _NATIVE_TEMPLATE); ndk-build is not, and
#                          is reported as `ndk_build` instead.
#   ndk_build              build.gradle drives ndk-build (Android.mk), which
#                          nothing here runs.
#   unresolved_dep         a dependency coordinate could not be read statically:
#                          a variable defined outside the file, or a version
#                          supplied by a BOM. Resolving it would mean executing
#                          Groovy.
#   prebuilt_jni_libs      the module ships no buildable native source and
#                          expects prebuilt .so files under src/main/jniLibs,
#                          which a Gradle task downloads on demand. Building
#                          from source is not an option, so the answer is a
#                          recipe -- see plugins.package() below.
#
# Removing an entry here is the *global* mechanism for widening support: no
# consumer, and no other part of this file, encodes the distinction.
# `external_native_build` left this list when the CMake path landed.
#
# There is now a second, per-package mechanism, and the two compose. A reason is
# gated unless the package has a recipe -- `plugins.package(bzl_file =, macro =)`
# -- in which case generation is handed over wholesale and the gate does not
# apply, because the recipe is by definition an answer to it. That is what keeps
# this list honest: `prebuilt_jni_libs` stays gated for every package that has
# not been given an answer, instead of being deleted globally the moment one
# plugin needs it.
_GATED_REASONS = [
    "ndk_build",
    "unresolved_dep",
    "prebuilt_jni_libs",
]

# Two things a module can say that mean "I compile native code", matched in
# _native_build_reasons. `ndkVersion` is deliberately not one of them: it pins
# *which* NDK AGP uses if something needs one, and the current Flutter plugin
# template sets it unconditionally (`ndkVersion = flutter.ndkVersion`), so it
# says nothing about whether the module compiles anything. Treating it as a
# marker classified integration_test -- which ships no native code at all -- as
# a CMake plugin, and the build then died looking for a CMakeLists that was
# never going to exist.
_NATIVE_BLOCK = "externalNativeBuild"
_CMAKELISTS = "CMakeLists"

# ndk-build is the other externalNativeBuild backend. It is driven by an
# Android.mk rather than a CMakeLists, so the CMake path cannot build it.
_NDK_BUILD_MARKERS = [
    "ndkBuild",
    "Android.mk",
]

# NDK 28 is the floor because it is the first release that defaults to 16 KB
# page alignment. NDK 27 *supports* 16 KB but still emits 4 KB-aligned LOAD
# segments by default, and a 4 KB-aligned .so does not merely fail to load on
# an API 35 device -- it segfaults the loader, with no dlerror() and no message.
# Measured across 26.3 / 27.2 / 28.2; see docs/plugins.md.
_MIN_NDK_MAJOR = 28

# Dependency configurations that put classes on the compile/runtime classpath.
# `testImplementation` and `androidTestImplementation` are deliberately absent:
# they carry a capital I, so they do not match, and they are not part of the
# published library anyway.
_DEP_CONFIGURATIONS = [
    "implementation",
    "api ",
    "api(",
    "compileOnly",
    "runtimeOnly",
]

_BUILD_LOADS = """# Generated by //tools/flutter:plugins.bzl -- do not edit.
load("@rules_android//rules:rules.bzl", "android_library")
"""

# Kotlin is the default language of the Flutter plugin template, so a plugin's
# Android half is as likely to be .kt as .java -- rive_common's is. android_library
# rejects .kt outright ("misplaced here, expected .java or .srcjar"), so those
# plugins are built with kt_android_library, which rules_kotlin derives from
# android_library's own attributes and is otherwise a drop-in.
_KOTLIN_BUILD_LOADS = """load("@rules_kotlin//kotlin:android.bzl", "kt_android_library")
"""

# Loaded only into the BUILD of a plugin that actually has a CMake build, so a
# project with no native plugins never pulls rules_foreign_cc into analysis.
_NATIVE_BUILD_LOADS = """load("@rules_foreign_cc//foreign_cc:defs.bzl", "cmake")
load("@rules_java//java:defs.bzl", "java_import")
load("{defs}", "android_native_lib_jar")
"""

_BUILD_PACKAGE = """
package(default_visibility = ["//visibility:public"])
"""

# Kept for the aggregate and gated BUILD files, which need no extra loads.
_BUILD_HEADER = _BUILD_LOADS + _BUILD_PACKAGE

_PLUGIN_TEMPLATE = """
# {name}, built from the Gradle module the pub package ships.
# {path}
{rule}(
    name = "{name}",
    srcs = {srcs},
    manifest = "android/src/main/AndroidManifest.xml",
    # The plugin manifest carries more than a package name -- connectivity_plus
    # declares ACCESS_NETWORK_STATE -- and it has to reach the APK, so it is
    # exported up the dependency chain to android_binary rather than consumed
    # locally.
    #
    # 1 rather than True for kt_android_library: it is built from rules_android's
    # raw attrs, where exports_manifest is the underlying tri-state int, while the
    # android_library *macro* accepts a bool and converts.
    exports_manifest = {exports_manifest},
    custom_package = "{package}",
    resource_files = {resource_files},
    deps = [
        # The embedding is an `api` dependency of every plugin under Gradle, so
        # AGP can desugar the default interface methods FlutterPlugin declares.
        # See flutter/flutter#72185 and PluginHandler.addEmbeddingDependencyToPlugin.
        "{embedding}",{deps}
    ],
)
"""

# The native half. Three targets rather than one because each boundary is a
# different concern: cmake() compiles, android_native_lib_jar packages (and
# pins the Android platform), java_import puts the jar on the classpath where
# android_binary looks for lib/<abi>/*.so.
#
# The .so is attached to the plugin's android_library as an ordinary dep, so it
# reaches the APK through @flutter_plugins//:all like everything else -- the
# label a consumer names is still just @flutter_plugins//<name>.
_NATIVE_TEMPLATE = """
# {name}'s native half: {libs}, from the plugin's own CMakeLists.
#
# The plugin's CMakeLists is run as written, against the NDK's own
# android.toolchain.cmake -- the toolchain file AGP passes and the one the
# CMakeLists was tested against. Handing it over as a CMAKE_TOOLCHAIN_FILE
# cache entry suppresses rules_foreign_cc's synthesized crosstool, which does
# not link the NDK C++ STL.
#
# lib_source is the whole package root, enumerated. A plugin's CMakeLists
# routinely reaches outside android/ -- rive_common's pulls in ../ios and,
# through that, ../common_source -- and which directories it reaches into
# cannot be known without evaluating it, so no narrower set is predictable
# from here.
filegroup(
    name = "{name}_native_srcs",
    srcs = {native_srcs},
)

cmake(
    name = "{name}_native",
    lib_source = ":{name}_native_srcs",
    # CMakeLists.txt lives under android/, but its sources do not. Note
    # rules_foreign_cc's detect_root() picks the topmost *file* dirname, so this
    # is relative to the package root only because the package root has files.
    working_directory = "{cmake_dir}",
    cache_entries = {{
        "CMAKE_TOOLCHAIN_FILE": "{toolchain_file}",
        "ANDROID_ABI": "{abi}",
        "ANDROID_PLATFORM": "android-{api_level}",
        # NDK 28 defaults to 16 KB page alignment, but that default does not
        # survive this path: rules_android_ndk's cc_toolchain passes an explicit
        # -Wl,-z,max-page-size=4096, and rules_foreign_cc forwards the toolchain's
        # link flags into CMAKE_SHARED_LINKER_FLAGS. So the NDK version alone is
        # not enough here and the alignment has to be restated.
        #
        # cache_entries are appended *after* the toolchain's own values, so this
        # is the later -z max-page-size and wins.
        #
        # Getting this wrong is not a clean failure: a 4 KB-aligned .so
        # segfaults the loader on a 16 KB-page device (API 35), with no
        # dlerror() and nothing in logcat. Verify with
        # `llvm-readelf -l <so> | grep LOAD` -- want 0x4000, not 0x1000.
        "CMAKE_SHARED_LINKER_FLAGS": "-Wl,-z,max-page-size=16384",
    }},
    generate_args = ["-GNinja"],
    # The plugin declares no install() rules -- there is nothing for
    # `cmake --install` to do -- so the libraries are lifted out by hand.
    install = False,
    out_shared_libs = {libs},
    postfix_script = "mkdir -p $$INSTALLDIR/lib && cp {lib_copy} $$INSTALLDIR/lib/",
)

android_native_lib_jar(
    name = "{name}_native_jar",
    src = [":{name}_native"],
    abi = "{abi}",
)

java_import(
    name = "{name}_native_import",
    jars = [":{name}_native_jar"],
)
"""

_GATED_TEMPLATE = """
# {name} is not supported: {reasons}.
#
# This target exists so the rest of the repository still fetches and builds.
# Building it fails with the reason; nothing else is affected.
genrule(
    name = "{name}_unsupported",
    outs = ["{name}_unsupported.java"],
    cmd = "echo 'Flutter plugin {name} is not supported: {reasons}.' >&2; " +
          "echo 'To fix, {hint}, or drop a reason code from ' >&2; " +
          "echo '_GATED_REASONS in tools/flutter/plugins.bzl.' >&2; " +
          "exit 1",
)

android_library(
    name = "{name}",
    srcs = [":{name}_unsupported"],
)
"""

# A package built by a recipe. The generated BUILD does nothing but hand over:
# load the macro the consuming project named, and call it with the facts.
#
# The `@@` is load bearing. This repository's repo mapping is *this module's*,
# so an apparent name like `@rules_kotlin//...` written here would resolve
# against this module's bazel_deps, and the user's repos are not reachable by
# apparent name at all. A canonical label bypasses repo mapping -- and once the
# user's .bzl is loaded, its own load() statements resolve in *their* mapping, so
# a recipe can use rulesets this module has never heard of.
_RECIPE_TEMPLATE = """
# {name} is built by a recipe supplied by the consuming project:
#   {bzl}%{macro}
# rather than by the standard generator.{gate_note}
#
# The facts the generator would have used are in package_info.bzl beside this
# file. It is a struct rather than a macro signature so the contract can grow
# without breaking every recipe; `contract_version` is there to be checked.
load("{bzl}", "{macro}")
load(":package_info.bzl", "PACKAGE_INFO")

{macro}(
    name = "{name}",
    info = PACKAGE_INFO,
)
"""

_PACKAGE_INFO_TEMPLATE = '''# Generated by //tools/flutter:plugins.bzl -- do not edit.
#
# Everything the standard generator knows about {name}, handed to its recipe.
# Paths are relative to this package. Sources are enumerated rather than left to
# a glob() because the tree is reached through symlinks into ~/.pub-cache, which
# glob() does not see through reliably.
PACKAGE_INFO = struct(
    # Bumped when a field is removed or changes meaning. Adding a field does not
    # bump it, which is the point of passing a struct at all.
    contract_version = 1,
    name = "{name}",
    # False for a package that is not a Flutter plugin -- no android/ module, and
    # nothing in .flutter-plugins-dependencies refers to it. Most of the fields
    # below are then empty.
    is_plugin = {is_plugin},
    # Every file staged for this package, root-relative. `android_srcs` and
    # `resource_files` below are this list *classified*, and classification is
    # exactly the thing a recipe may need to route around: a source the generator
    # put in the wrong bucket, or dropped, is still present here.
    #
    # This is what makes a recipe a real escape hatch rather than a slightly
    # different view of the same mistake. `flutter_image_compress_common` ships
    # ExifKeeper.java under src/main/kotlin/, which the enumerator missed
    # entirely; a recipe could have recovered with
    #
    #     srcs = [f for f in info.all_files
    #             if f.startswith("android/src/main/") and f.endswith((".java", ".kt"))]
    #
    # without knowing which file had been dropped.
    all_files = {all_files},
    android_srcs = {android_srcs},
    android_manifest = {android_manifest},
    resource_files = {resource_files},
    namespace = {namespace},
    # Maven coordinates scraped from the plugin's build.gradle, already merged
    # into the single maven.install. Labels here are resolvable.
    coordinates = {coordinates},
    plugin_deps = {plugin_deps},
    # Reason codes the generator raised. A recipe exists to answer these, so it
    # is given them rather than having to rediscover them.
    reasons = {reasons},
    abi = "{abi}",
    api_level = {api_level},
    embedding = "{embedding}",
)
'''

# Loaded into the aggregate BUILD only, which is why it is separate from
# _BUILD_LOADS: a plugin's own BUILD has no use for these.
_NATIVE_LIBS_LOADS = """load("{recipe}", "flutter_native_libs")
load("@rules_java//java:defs.bzl", "java_import")
"""

# The second aggregate: every .so that a recipe contributed, in one jar, wrapped
# so the app can name a single label.
#
# A recipe *must* define `<name>_flutter_native` -- that is the contract, and
# depending on it by convention is what makes a forgotten one fail at analysis
# instead of producing a target nothing references. Which was the original defect
# this milestone exists to prevent.
_NATIVE_LIBS_TEMPLATE = """
flutter_native_libs(
    name = "native_libs_jar",
    abi = "{abi}",
    deps = [{deps}
    ],
)

java_import(
    name = "native_libs",
    jars = [":native_libs_jar"],
)
"""

_MODULE_SEGMENT_HEADER = """# Generated by //tools/flutter:plugins.bzl -- do not edit by hand.
#
# The complete Maven artifact list: the Flutter embedding's own dependencies
# (from //tools/flutter:embedding.bzl) merged with the coordinates extracted
# from every plugin's android/build.gradle. Regenerate with:
#
#     bazel build //app:plugins_check
#
# which prints this file's expected contents when it drifts.
#
# This is the *only* maven.install for @flutter_maven, deliberately. Two install
# tags sharing a repository name merge into one resolution and the later tag
# wins outright -- not highest-version, not declaration order -- so splitting
# the list let a plugin silently downgrade an artifact the embedding declared.
# One list, resolved once, with highest-wins applied across all of it.
maven = use_extension("@rules_jvm_external//:extensions.bzl", "maven")
maven.install(
    name = "flutter_maven",
    artifacts = [{artifacts}
    ],
    repositories = [
        "https://maven.google.com",
        "https://repo1.maven.org/maven2",
    ],
{resolution}
)
use_repo(maven, "flutter_maven")
"""




# Two ways to settle versions, and which one a project needs depends on its
# dependency graph rather than on taste -- so the consumer picks.
#
# coursier is the default and resolves a small graph fine. It cannot resolve a
# large AndroidX one: those poms carry Maven *strict* ranges (the same artifact
# demanded as `[2.7.0,2.7.0]` down one path and `[2.5.1,2.5.1]` down another),
# which no POM-based resolver can satisfy. Gradle reads the Gradle Module
# Metadata AndroidX also publishes, where the constraints are loose, and is the
# only resolver that gets through -- at the cost of requiring a lock file, which
# only coursier may omit.
_COURSIER_RESOLUTION = """    # Every artifact above is already reduced to one version, so "pinned" makes
    # those chosen versions authoritative over transitive suggestions rather
    # than failing resolution when a pom asks for something older.
    version_conflict_policy = "pinned","""

_PINNED_RESOLUTION = """    resolver = "{resolver}",
    # Only the coursier resolver may omit a lock file. Repin with
    # `bazel run @flutter_maven//:pin` -- note @unpinned_flutter_maven's alias is
    # broken under bzlmod.
    lock_file = "{lock_file}","""


def _module_segment(coordinates, resolver, lock_file):
    return _MODULE_SEGMENT_HEADER.format(
        artifacts = "".join([
            "\n        \"{}\",".format(c)
            for c in highest_versions(coordinates)
        ]),
        resolution = (
            _COURSIER_RESOLUTION if resolver == "coursier" else _PINNED_RESOLUTION.format(
                resolver = resolver,
                lock_file = lock_file,
            )
        ),
    )


def _strip_buildscript(text):
    """Drop `buildscript { ... }` blocks.

    Their `classpath` entries are the AGP version the plugin builds *itself*
    with, not dependencies of the produced library, so counting them would gate
    every plugin in existence.
    """
    out = []
    rest = text
    for _ in range(10):
        start = rest.find("buildscript")
        if start == -1:
            break
        brace = rest.find("{", start)
        if brace == -1:
            break
        depth = 0
        end = -1
        for i in range(brace, len(rest)):
            c = rest[i]
            if c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
                if depth == 0:
                    end = i + 1
                    break
        if end == -1:
            break
        out.append(rest[:start])
        rest = rest[end:]
    out.append(rest)
    return "".join(out)


def _quoted(line):
    """The first single- or double-quoted run in `line`, or None."""
    for quote in ["\"", "'"]:
        start = line.find(quote)
        if start == -1:
            continue
        end = line.find(quote, start + 1)
        if end == -1:
            continue
        return line[start + 1:end]
    return None


def _collect_variables(body):
    """Gradle variables assigned a string literal in this file.

    Covers `ext.foo = '1.2'`, `foo = '1.2'` inside an `ext {}` block, and
    `def foo = '1.2'`. This is string scraping, not evaluation -- anything
    computed, conditional, or defined in the root project stays unresolved and
    becomes an `unresolved_dep` reason rather than a guess.
    """
    variables = {}
    for line in body.split("\n"):
        stripped = line.strip()
        if stripped.startswith("//"):
            continue
        if "=" not in stripped:
            continue
        name = stripped.split("=")[0].strip()
        for prefix in ["def ", "ext."]:
            if name.startswith(prefix):
                name = name[len(prefix):].strip()
        if not name or " " in name or "." in name:
            continue
        value = _quoted(stripped[stripped.find("=") + 1:])
        if value != None and "$" not in value:
            variables[name] = value
    return variables


def _substitute(coordinate, variables):
    """Replace $var / ${var} in a coordinate. Returns None if any is unknown."""
    out = ""
    rest = coordinate
    for _ in range(10):
        at = rest.find("$")
        if at == -1:
            out += rest
            return out
        out += rest[:at]
        rest = rest[at + 1:]
        if rest.startswith("{"):
            end = rest.find("}")
            if end == -1:
                return None
            name = rest[1:end]
            rest = rest[end + 1:]
        else:
            end = len(rest)
            for i in range(len(rest)):
                c = rest[i]
                if not (c.isalnum() or c == "_"):
                    end = i
                    break
            name = rest[:end]
            rest = rest[end:]
        if name not in variables:
            return None
        out += variables[name]
    return None


def _extract_dependencies(build_gradle_text):
    """Return (coordinates, reasons) for one plugin's build.gradle.

    Gradle is the only thing that can truly evaluate this file, but the
    dependency block is overwhelmingly literal in practice, and the cases that
    are not fall into a small set that this reports rather than guesses at.
    """
    body = _strip_buildscript(build_gradle_text)
    variables = _collect_variables(body)

    # Markers are matched against the code alone, and `externalNativeBuild` only
    # where it opens a block. rive_native names it in a comment *and* in a task
    # name it matches on (`it.name.startsWith("externalNativeBuild")`) while
    # declaring no native build whatsoever; a substring search over the whole
    # file classified it as a CMake plugin and the fetch then died looking for a
    # CMakeLists that does not exist. A CMakeLists named by `path` stays a plain
    # substring match -- specific enough by itself, and it is not always the
    # first token on its line.
    code_lines = [
        line
        for line in body.split("\n")
        if not line.strip().startswith("//")
    ]
    code = "\n".join(code_lines)

    coordinates = []
    reasons = []

    declares_native = _CMAKELISTS in code
    for line in code_lines:
        if line.strip().startswith(_NATIVE_BLOCK):
            declares_native = True
            break
    if declares_native:
        reasons.append("external_native_build")

    # ndk-build is a separate backend from CMake and nothing here runs it, so it
    # is reported under its own code and stays gated.
    for marker in _NDK_BUILD_MARKERS:
        if marker in code:
            if "ndk_build" not in reasons:
                reasons.append("ndk_build")
            break

    # No native build of its own, yet it expects .so files under jniLibs: the
    # libraries come from somewhere outside the build. rive_native downloads
    # them in a Gradle Exec task that shells out to `dart run rive_native:setup`.
    # Left ungated this would compile to a perfectly good android_library with no
    # library behind it, and fail on the first FFI call at runtime.
    if not declares_native and "jniLibs" in code:
        reasons.append("prebuilt_jni_libs")

    for line in body.split("\n"):
        stripped = line.strip()
        if stripped.startswith("//"):
            continue

        matched = False
        for configuration in _DEP_CONFIGURATIONS:
            if stripped.startswith(configuration):
                matched = True
                break
        if not matched:
            continue

        # `implementation platform("...")` imports a BOM: the coordinates it
        # governs are then written without a version. rules_jvm_external can
        # express this via maven.install(boms = ...), but picking the BOM up
        # automatically would mean resolving its version too, so it is reported.
        if "platform(" in stripped:
            if "unresolved_dep" not in reasons:
                reasons.append("unresolved_dep")
            continue

        coordinate = _quoted(stripped)
        if coordinate == None:
            continue

        resolved = _substitute(coordinate, variables)

        # kotlin-stdlib comes from the rules_kotlin toolchain, so its version is
        # not ours to resolve and declaring it would fight the toolchain. This is
        # the single most common unresolved coordinate in the pub ecosystem --
        # the plugin template writes `$kotlin_version`, defined in the *root*
        # project, so it is never readable from the plugin's own build.gradle.
        if coordinate.startswith("org.jetbrains.kotlin:kotlin-stdlib"):
            continue

        if resolved == None or resolved.count(":") != 2:
            if "unresolved_dep" not in reasons:
                reasons.append("unresolved_dep")
            continue

        if resolved not in coordinates:
            coordinates.append(resolved)

    return coordinates, reasons




_DART_REGISTRANT_TEMPLATE = '''//
// Generated by //tools/flutter:plugins.bzl -- do not edit.
//
// The Dart half of plugin registration. GeneratedPluginRegistrant.java
// instantiates each plugin's *native* class; a federated plugin also ships a
// Dart implementation of its platform interface, declared as `dartPluginClass`
// in the plugin's pubspec, and that half is registered from here.
//
// Nothing imports this file. frontend_server is given it via --source, and the
// engine finds it through the `flutter.dart_plugin_registrant` environment
// define, which package:flutter/src/dart_plugin_registrant.dart reads into a
// const. Hence the vm:entry-point pragmas: nothing references these symbols, so
// tree shaking would otherwise drop them.

import 'dart:io'; // flutter_ignore: dart_io_import.

{imports}
@pragma('vm:entry-point')
class _PluginRegistrant {{

  @pragma('vm:entry-point')
  static void register() {{
    if (Platform.isAndroid) {{
{registrations}    }}
  }}
}}
'''

_DART_REGISTRATION = '''      try {{
        {name}.{dart_class}.registerWith();
      }} catch (err) {{
        print(
          '`{name}` threw an error: $err. '
          'The app may not function as expected until you remove this plugin from pubspec.yaml'
        );
      }}
'''


def _dart_plugin_class(ctx, package_root, name):
    """Read `flutter: plugin: platforms: android: dartPluginClass` from a pubspec.

    Returns (dartClass, dartFileName) or (None, None). The metadata file does
    not carry these -- only Gradle's view of a plugin is in there -- so the
    plugin's own pubspec is the source.

    This is indentation-driven rather than a real YAML parse, which is why it
    checks the nesting it walks rather than scanning for a bare key: a
    `dartPluginClass` under ios: must not be picked up for android.
    """
    pubspec = ctx.path("{}/pubspec.yaml".format(package_root))
    if not pubspec.exists:
        return None, None

    in_flutter = False
    in_plugin = False
    in_platforms = False
    in_android = False
    dart_class = None
    dart_file = None

    for raw in ctx.read(pubspec).split("\n"):
        line = raw.split("#")[0].rstrip()
        if not line.strip():
            continue
        indent = len(line) - len(line.lstrip())
        key = line.strip().split(":")[0].strip()
        value = line.strip()[len(key) + 1:].strip() if ":" in line else ""

        if indent == 0:
            in_flutter = key == "flutter"
            in_plugin = False
            in_platforms = False
            in_android = False
            continue
        if not in_flutter:
            continue
        if indent <= 2:
            in_plugin = key == "plugin"
            in_platforms = False
            in_android = False
            continue
        if not in_plugin:
            continue
        if indent <= 4:
            in_platforms = key == "platforms"
            in_android = False
            continue
        if not in_platforms:
            continue
        if indent <= 6:
            in_android = key == "android"
            continue
        if in_android:
            if key == "dartPluginClass":
                dart_class = value
            elif key == "dartFileName":
                dart_file = value

    if dart_class == None:
        return None, None
    # flutter_tools defaults the file to <pluginName>.dart when unspecified.
    return dart_class, dart_file if dart_file else "{}.dart".format(name)


def _namespace(build_gradle_text):
    """Read the `namespace` AGP assigns the module, from build.gradle.

    AGP 7 deprecated the manifest's `package=` and AGP 8 removed it, so a plugin
    written against a current AGP declares its package name here instead and
    ships a bare `<manifest />`. This is the authoritative source of the two:
    where both exist AGP errors on a disagreement rather than reconciling them.

    Matched line by line rather than by substring, so that `testNamespace` and a
    coordinate mentioning the word are not mistaken for it. `namespace 'x'`
    (Groovy) and `namespace = "x"` (Kotlin, and the Groovy assignment form) are
    both accepted.
    """
    for line in _strip_buildscript(build_gradle_text).splitlines():
        stripped = line.strip()
        if not stripped.startswith("namespace"):
            continue
        rest = stripped[len("namespace"):].lstrip()
        if rest.startswith("="):
            rest = rest[1:].lstrip()
        if not rest or rest[0] not in "'\"":
            continue
        quote = rest[0]
        end = rest.find(quote, 1)
        if end == -1:
            continue
        return rest[1:end]
    return None


def _manifest_package(ctx, manifest_path):
    """Read the `package=` attribute from a library manifest.

    The pre-AGP-8 spelling of `namespace`, and the fallback for a plugin that
    predates the migration. Bazel's android rules still read this attribute, so
    where it is present it needs no translation.
    """
    text = ctx.read(manifest_path)
    marker = "package="
    at = text.find(marker)
    if at == -1:
        return None
    quote = text[at + len(marker)]
    end = text.find(quote, at + len(marker) + 1)
    return text[at + len(marker) + 1:end]


def _list_files(ctx, root, subdir, extensions):
    """Enumerate files under `root/subdir`, returned as `subdir`-relative paths.

    Files are listed here rather than left to a `glob()` in the generated BUILD
    because the tree is reached through a directory symlink into ~/.pub-cache.
    Enumerating makes the generated target explicit and reviewable, and pub
    package contents are immutable for a given version, so nothing is lost.
    """
    found = []
    directory = root.get_child(subdir)
    if not directory.exists:
        return found

    pending = [directory]
    for _ in range(1000):
        if not pending:
            break
        current = pending.pop()
        for child in current.readdir():
            if child.is_dir:
                pending.append(child)
                continue
            name = str(child)
            if extensions and not [e for e in extensions if name.endswith(e)]:
                continue
            found.append(name[len(str(root)) + 1:])
    return sorted(found)


def _list_all_files(ctx, root, skip_dirs):
    """Every file under `root`, as root-relative paths.

    Used for the CMake source set. Enumerated rather than globbed for the same
    reason the Java sources are: the tree is reached through symlinks into
    ~/.pub-cache. It also has to be the whole package root -- a plugin's
    CMakeLists routinely reaches outside android/, and which directories it
    reaches into cannot be known without evaluating it.
    """
    found = []
    pending = [root]

    # Bounded because a repository rule must terminate; a pub package is a few
    # hundred directories, so this is slack, not a limit anyone reaches.
    for _ in range(20000):
        if not pending:
            break
        current = pending.pop()
        for child in current.readdir():
            name = child.basename
            if name.startswith("."):
                continue
            if child.is_dir:
                if name not in skip_dirs:
                    pending.append(child)
                continue
            found.append(str(child)[len(str(root)) + 1:])
    return sorted(found)


def _cmake_subdirectory(build_gradle_text):
    """The directory holding the CMakeLists, relative to the package root.

    `externalNativeBuild { cmake { path "CMakeLists.txt" } }` names a path
    relative to the Gradle module, i.e. to android/.
    """
    at = build_gradle_text.find("externalNativeBuild")
    if at == -1:
        return "android"

    # `path` is the only string in the cmake block that matters; take the first
    # one after the marker rather than parsing Groovy.
    region = build_gradle_text[at:]
    path_at = region.find("path")
    if path_at == -1:
        return "android"
    relative = _quoted(region[path_at:region.find("\n", path_at) + 1 or len(region)])
    if not relative:
        return "android"

    # Keep the directory, drop the CMakeLists filename.
    parts = [p for p in relative.split("/") if p and p != "."]
    if parts and parts[-1].endswith(".txt"):
        parts = parts[:-1]
    return "/".join(["android"] + parts)


def _cmake_output_names(cmakelists_text):
    """Target -> OUTPUT_NAME, for targets that rename their artifact.

    `set_target_properties(<target> PROPERTIES ... OUTPUT_NAME "<name>")` makes
    the file `lib<name>.so` rather than `lib<target>.so`. Missing this is not a
    silent error but it is a confusing one: the CMake build *succeeds* and the
    copy afterwards fails with `cp: libjni.so: No such file or directory`,
    which reads as a build failure rather than a naming mismatch.

    `jni` (jnigen's runtime) is the case that surfaced it -- `add_library(jni
    SHARED ...)` followed by `OUTPUT_NAME "dartjni"`.
    """
    names = {}
    rest = cmakelists_text
    for _ in range(100):
        at = rest.find("set_target_properties")
        if at == -1:
            break
        rest = rest[at + len("set_target_properties"):]
        close = rest.find(")")
        if close == -1:
            break
        block = rest[:close]
        marker = block.find("OUTPUT_NAME")
        if marker == -1:
            continue

        # The target is the first argument; the new name is the first quoted
        # run after the keyword. A generator expression in either is not
        # something string scraping can resolve, so it is left alone and the
        # add_library name stands.
        head = block.replace("(", " ")
        for whitespace in ["\n", "\r", "\t"]:
            head = head.replace(whitespace, " ")
        arguments = [a for a in head.split(" ") if a]
        if not arguments:
            continue
        target = arguments[0]
        output = _quoted(block[marker:])
        if output and "$" not in target and "$" not in output:
            names[target] = output
    return names


def _cmake_shared_libraries(cmakelists_text):
    """Names of the SHARED libraries a CMakeLists defines, as lib<name>.so.

    rules_foreign_cc has to be told what to expect, and getting this wrong is
    loud: the build fails with the file missing rather than producing a
    silently empty result.
    """
    output_names = _cmake_output_names(cmakelists_text)
    libraries = []
    rest = cmakelists_text
    for _ in range(100):
        at = rest.find("add_library")
        if at == -1:
            break
        rest = rest[at + len("add_library"):]
        close = rest.find(")")
        if close == -1:
            break
        # Starlark's split() needs an explicit separator, so normalise the
        # whitespace CMake allows between arguments and drop the empties.
        head = rest[:close].replace("(", " ")
        for whitespace in ["\n", "\r", "\t"]:
            head = head.replace(whitespace, " ")
        arguments = [a for a in head.split(" ") if a]
        # add_library(<name> [STATIC|SHARED|MODULE] ...). Only SHARED produces a
        # .so; a STATIC helper library is linked into one and never shipped.
        if len(arguments) >= 2 and "SHARED" in arguments[1:]:
            name = arguments[0]
            # The artifact is named after OUTPUT_NAME where one is set, not
            # after the CMake target.
            name = output_names.get(name, name)
            if "$" not in name and "lib{}.so".format(name) not in libraries:
                libraries.append("lib{}.so".format(name))
    return libraries


def _ndk_root(ctx):
    """The NDK to build native plugins with, version-checked.

    Read from the same ANDROID_NDK_HOME that rules_android_ndk reads, so the
    cc_toolchain and the CMake toolchain file can never disagree about which
    NDK is in use.
    """
    ndk = ctx.getenv("ANDROID_NDK_HOME")
    if not ndk:
        fail(
            "This project has a Flutter plugin with a CMake native build, " +
            "which needs the Android NDK, but ANDROID_NDK_HOME is not set.\n" +
            "Set it to an NDK {}.0.0 or newer, e.g.\n".format(_MIN_NDK_MAJOR) +
            "    export ANDROID_NDK_HOME=$HOME/Library/Android/sdk/ndk/28.2.13676358",
        )

    properties = ctx.path("{}/source.properties".format(ndk))
    if not properties.exists:
        fail("ANDROID_NDK_HOME={} does not look like an NDK: no source.properties".format(ndk))

    revision = None
    for line in ctx.read(properties).split("\n"):
        if line.startswith("Pkg.Revision"):
            revision = line.split("=")[1].strip()
            break
    if not revision:
        fail("Could not read Pkg.Revision from {}/source.properties".format(ndk))

    major = revision.split(".")[0]
    if not major.isdigit() or int(major) < _MIN_NDK_MAJOR:
        # Not a style preference. Below 28 the NDK emits 4 KB-aligned LOAD
        # segments, and a 4 KB-aligned .so segfaults the loader on a 16 KB-page
        # device (API 35) with no dlerror() and no log line -- the APK builds,
        # installs and dies. Refusing here is the only loud moment available.
        fail(
            "ANDROID_NDK_HOME points at NDK {}, but {}.0.0 or newer is required.\n".format(
                revision,
                _MIN_NDK_MAJOR,
            ) +
            "NDK 27 and older default to 4 KB page alignment; such a .so " +
            "crashes the dynamic loader on 16 KB-page devices (Android 15, " +
            "API 35) rather than failing to load cleanly.",
        )

    toolchain_file = ctx.path("{}/build/cmake/android.toolchain.cmake".format(ndk))
    if not toolchain_file.exists:
        fail("NDK at {} has no build/cmake/android.toolchain.cmake".format(ndk))
    return str(toolchain_file)


def _package_roots(ctx):
    """Every pub package in the resolution, name -> absolute root.

    `.flutter-plugins-dependencies` lists only what Gradle would see: packages
    with an `android/` module. A recipe has to be able to name a package that is
    not a plugin at all -- `sqlite3` ships a Dart build hook and no Android
    module, so nothing in that file refers to it -- and `package_config.json`,
    written by the same `pub get`, resolves every package by name.

    Absolute file:// URIs into ~/.pub-cache, which is exactly why packages are
    reached through an external repository: Bazel cannot glob outside the
    workspace.
    """
    if not ctx.attr.package_config:
        return {}

    roots = {}
    config = json.decode(ctx.read(ctx.attr.package_config))
    for package in config.get("packages", []):
        root = package.get("rootUri", "")
        if root.startswith("file://"):
            roots[package["name"]] = root[len("file://"):].rstrip("/")
    return roots


def _stage_package(ctx, name, package_root):
    """Symlink a package's entries into `<name>/`, returning the staged root.

    A real directory of symlinked *entries*, never a symlink to the directory:
    ctx.file("<name>/BUILD.bazel") would otherwise write straight *through* the
    symlink into ~/.pub-cache, mutating a cache pub treats as immutable and
    shares with every project on the machine.
    """
    for child in ctx.path(package_root).readdir():
        if child.basename.startswith("."):
            continue
        ctx.symlink(child, "{}/{}".format(name, child.basename))
    return ctx.path(name)


def _write_recipe(ctx, name, recipe, info, gate_note = ""):
    """Emit the hand-over BUILD and the package_info.bzl beside it."""
    ctx.file(
        "{}/BUILD.bazel".format(name),
        _BUILD_PACKAGE + _RECIPE_TEMPLATE.format(
            name = name,
            bzl = recipe["bzl"],
            macro = recipe["macro"],
            gate_note = gate_note,
        ),
    )
    ctx.file("{}/package_info.bzl".format(name), _PACKAGE_INFO_TEMPLATE.format(**info))


def _flutter_plugins_impl(ctx):
    metadata = json.decode(ctx.read(ctx.attr.metadata))
    plugins = metadata.get("plugins", {}).get("android", [])
    overrides = {k: json.decode(v) for k, v in ctx.attr.overrides.items()}
    recipes = {k: json.decode(v) for k, v in ctx.attr.recipes.items()}

    manifest = []
    all_coordinates = []
    dart_registrations = []

    # Names a recipe was registered for that the plugin loop never reached --
    # either not a plugin at all, or a Dart-only implementation. Whittled down as
    # plugins are processed; whatever is left is handled afterwards.
    unmatched_recipes = {k: v for k, v in recipes.items()}

    # Resolved on first use, so a project with no CMake plugin needs no NDK at
    # all -- and one that does gets the version check before anything is
    # generated.
    toolchain_file = None
    for plugin in plugins:
        name = plugin["name"]
        package_root = plugin["path"].rstrip("/")

        # The Dart half is independent of whether there is anything to compile:
        # a Dart-only implementation of a federated plugin still has to register
        # its platform interface. Collected before the native_build check for
        # exactly that reason.
        dart_class, dart_file = _dart_plugin_class(ctx, package_root, name)
        if dart_class:
            dart_registrations.append((name, dart_class, dart_file))

        # Dart-only implementations have no Gradle module to build.
        if not plugin.get("native_build", True):
            continue

        # `path` is the package root; the Gradle module is one level down. It is
        # an absolute path into ~/.pub-cache, which is why plugins have to be
        # reached through an external repository at all: Bazel cannot glob
        # outside the workspace.
        android = "{}/android".format(package_root)

        build_gradle = ctx.path("{}/build.gradle".format(android))
        if not build_gradle.exists:
            build_gradle = ctx.path("{}/build.gradle.kts".format(android))
        if not build_gradle.exists:
            fail("Plugin {} declares an Android build but has no build.gradle at {}".format(name, android))

        coordinates, reasons = _extract_dependencies(ctx.read(build_gradle))
        # An override supplies coordinates the scraper could not read, which is
        # the per-plugin escape hatch from `unresolved_dep`. It is the only way
        # out for a BOM-versioned plugin: an AAR would not help, because an AAR
        # does not carry its dependencies.
        override = overrides.get(name)
        if override != None:
            coordinates = coordinates + [c for c in override if c not in coordinates]
            reasons = [r for r in reasons if r != "unresolved_dep"]

        gated = [r for r in reasons if r in _GATED_REASONS]

        # A recipe takes over generation for this plugin entirely, gate and all.
        # Checked before the gate rather than after: a recipe is by definition an
        # answer to whatever reason was raised, and the reasons are passed on so
        # it can see what it is answering.
        #
        # It applies to healthy plugins too. Someone may know a better way to
        # build a package than the generator does, and refusing that would only
        # push them to fork the rules -- so the substitution is allowed and
        # recorded in plugins.json instead of being prevented.
        recipe = unmatched_recipes.pop(name, None)
        if recipe != None:
            _stage_package(ctx, name, package_root)
            root = ctx.path(name)
            # Both roots, both extensions -- see the note on the standard path.
            java_srcs = (
                _list_files(ctx, root, "android/src/main/java", [".java"]) +
                _list_files(ctx, root, "android/src/main/kotlin", [".java"])
            )
            kotlin_srcs = (
                _list_files(ctx, root, "android/src/main/kotlin", [".kt"]) +
                _list_files(ctx, root, "android/src/main/java", [".kt"])
            )
            package = _namespace(ctx.read(build_gradle))
            if not package:
                manifest_path = root.get_child("android/src/main/AndroidManifest.xml")
                if manifest_path.exists:
                    package = _manifest_package(ctx, manifest_path)
            _write_recipe(
                ctx,
                name,
                recipe,
                {
                    "name": name,
                    "is_plugin": "True",
                    "all_files": repr(_list_all_files(ctx, root, ["build"])),
                    "android_srcs": repr(java_srcs + kotlin_srcs),
                    "android_manifest": repr("android/src/main/AndroidManifest.xml"),
                    "resource_files": repr(_list_files(ctx, root, "android/src/main/res", [])),
                    "namespace": repr(package),
                    "coordinates": repr([maven_label(c) for c in coordinates]),
                    "plugin_deps": repr([
                        "//{n}:{n}".format(n = d)
                        for d in plugin.get("dependencies", [])
                    ]),
                    "reasons": repr(reasons),
                    "abi": ctx.attr.abi,
                    "api_level": ctx.attr.api_level,
                    "embedding": ctx.attr.embedding,
                },
                gate_note = (
                    "\n# Reasons that would otherwise gate it: {}.".format(", ".join(gated))
                    if gated
                    else ""
                ),
            )
            manifest.append({
                "name": name,
                "reasons": reasons,
                "strategy": "recipe:{}%{}".format(recipe["bzl"], recipe["macro"]),
                "coordinates": coordinates,
                "is_plugin": True,
            })
            all_coordinates.extend([c for c in coordinates if c not in all_coordinates])
            continue

        if gated:
            # Deliberately not a fail(): that aborts the repository fetch, so a
            # single unsupported plugin makes every *other* plugin unfetchable
            # too. Emitting a target that fails when built keeps the label
            # present and correctly typed, so unrelated targets still build and
            # the error names the plugin that actually caused it.
            ctx.file(
                "{}/BUILD.bazel".format(name),
                _BUILD_HEADER + _GATED_TEMPLATE.format(
                    name = name,
                    reasons = ", ".join(gated),
                    hint = (
                        "supply its coordinates with plugins.package(artifacts = ...)"
                        if "unresolved_dep" in gated
                        else "give it a recipe with plugins.package(bzl_file = ..., macro = ...)"
                    ),
                ),
            )
            manifest.append({
                "name": name,
                "reasons": reasons,
                "strategy": "gated",
                "coordinates": coordinates,
                "is_plugin": True,
            })
            continue

        # Stage the package root as a real directory of symlinked entries,
        # rather than symlinking the package root itself.
        #
        # Symlinking the directory means ctx.file("<name>/BUILD.bazel") writes
        # *through* the symlink, landing a generated BUILD file inside
        # ~/.pub-cache -- mutating a cache that pub treats as immutable and
        # shares between every project on the machine.
        #
        # It also has to be the package root and not android/: a CMake plugin's
        # CMakeLists reaches outside the Gradle module (rive_common's reaches
        # into ../ios and, through that, ../common_source).
        root = _stage_package(ctx, name, package_root)
        # Both source roots are scanned for *both* extensions, and the split is
        # by extension alone. The source set is what build.gradle names, not what
        # the directory is called: the Flutter template writes
        # `main.java.srcDirs += 'src/main/kotlin'`, which makes java/ and kotlin/
        # one set that AGP compiles together, so either may hold either.
        #
        # Scanning only java/ for .java missed flutter_image_compress_common,
        # whose ExifKeeper.**java** sits under src/main/kotlin/ beside the
        # Kotlin that calls it -- `unresolved reference 'ExifKeeper'`, from a
        # file that was simply never passed to the compiler.
        java_srcs = (
            _list_files(ctx, root, "android/src/main/java", [".java"]) +
            _list_files(ctx, root, "android/src/main/kotlin", [".java"])
        )
        kotlin_srcs = (
            _list_files(ctx, root, "android/src/main/kotlin", [".kt"]) +
            _list_files(ctx, root, "android/src/main/java", [".kt"])
        )
        srcs = java_srcs + kotlin_srcs
        if not srcs:
            fail("Plugin {} has no Android sources under {}/src/main".format(name, android))

        # Two spellings of one thing, tried newest first. Reading only the
        # manifest was enough for the demo app's plugins and is not enough in
        # the wild: four of smooth_app's thirty carry a bare `<manifest />` and
        # name themselves in build.gradle, while qr_code_scanner is the mirror
        # case, predating `namespace` entirely.
        package = _namespace(ctx.read(build_gradle))
        if not package:
            package = _manifest_package(ctx, root.get_child("android/src/main/AndroidManifest.xml"))
        if not package:
            fail(
                ("Plugin {} names itself nowhere this can read: no `namespace` in " +
                 "{}/build.gradle and no package= in its AndroidManifest.xml.").format(
                    name,
                    android,
                ),
            )

        # The native half, for plugins whose build.gradle drives CMake.
        native = ""
        native_deps = []
        if "external_native_build" in reasons:
            if toolchain_file == None:
                toolchain_file = _ndk_root(ctx)

            cmake_directory = _cmake_subdirectory(ctx.read(build_gradle))
            cmakelists = root.get_child(cmake_directory).get_child("CMakeLists.txt")
            if not cmakelists.exists:
                fail("Plugin {} declares externalNativeBuild but has no CMakeLists.txt at {}/{}".format(
                    name,
                    package_root,
                    cmake_directory,
                ))

            libraries = _cmake_shared_libraries(ctx.read(cmakelists))
            if not libraries:
                fail("Plugin {}'s CMakeLists at {}/{} defines no SHARED library".format(
                    name,
                    package_root,
                    cmake_directory,
                ))

            native = _NATIVE_TEMPLATE.format(
                name = name,
                libs = repr(libraries),
                lib_copy = " ".join(libraries),
                native_srcs = repr(_list_all_files(ctx, root, ["build"])),
                cmake_dir = cmake_directory,
                toolchain_file = toolchain_file,
                abi = ctx.attr.abi,
                api_level = ctx.attr.api_level,
            )
            native_deps = ["\n        \":{}_native_import\",".format(name)]

        ctx.file(
            "{}/BUILD.bazel".format(name),
            _BUILD_LOADS +
            (_KOTLIN_BUILD_LOADS if kotlin_srcs else "") +
            (_NATIVE_BUILD_LOADS.format(defs = ctx.attr.defs) if native else "") +
            _BUILD_PACKAGE +
            native +
            _PLUGIN_TEMPLATE.format(
                name = name,
                path = android,
                rule = "kt_android_library" if kotlin_srcs else "android_library",
                exports_manifest = "1" if kotlin_srcs else "True",
                srcs = repr(srcs),
                resource_files = repr(_list_files(ctx, root, "android/src/main/res", [])),
                package = package,
                deps = "".join(
                    # Plugins depend on each other: image_picker_android needs
                    # FlutterLifecycleAdapter from flutter_plugin_android_lifecycle.
                    # Gradle wires this in PluginHandler.configurePluginDependencies
                    # from the same "dependencies" field.
                    [
                        "\n        \"//{n}:{n}\",".format(n = d)
                        for d in plugin.get("dependencies", [])
                    ] + [
                        "\n        \"{}\",".format(maven_label(c))
                        for c in coordinates
                    ] + native_deps,
                ),
                embedding = ctx.attr.embedding,
            ),
        )
        manifest.append({
            "name": name,
            "reasons": reasons,
            "strategy": "source+cmake" if native else "source",
            "coordinates": coordinates,
            "is_plugin": True,
        })
        all_coordinates.extend([c for c in coordinates if c not in all_coordinates])

    # Recipes for packages the loop above never reached. This is the whole reason
    # the registry is keyed on *pub package* rather than on plugin: `sqlite3`
    # ships a Dart build hook and no android/ module, so it appears nowhere in
    # .flutter-plugins-dependencies and a plugin-keyed registry could never name
    # it. package_config.json, written by the same `pub get`, resolves it.
    if unmatched_recipes:
        roots = _package_roots(ctx)
        for name in sorted(unmatched_recipes.keys()):
            recipe = unmatched_recipes[name]
            if name not in roots:
                fail(
                    ("plugins.package() registered a recipe for `{}`, but no such " +
                     "package is in the resolution.\n" +
                     "Checked .flutter-plugins-dependencies and {}.\n" +
                     "Either the name is misspelled, or the package is not a " +
                     "dependency of this app.").format(
                        name,
                        ctx.attr.package_config or "(no package_config given)",
                    ),
                )
            _stage_package(ctx, name, roots[name])
            root = ctx.path(name)
            _write_recipe(ctx, name, recipe, {
                "name": name,
                "all_files": repr(_list_all_files(ctx, root, ["build"])),
                # Not a plugin: no Gradle module, so none of the Android facts
                # exist and a recipe for one of these is normally doing nothing
                # but attaching a library.
                "is_plugin": "False",
                "android_srcs": repr([]),
                "android_manifest": repr(None),
                "resource_files": repr([]),
                "namespace": repr(None),
                "coordinates": repr([]),
                "plugin_deps": repr([]),
                "reasons": repr([]),
                "abi": ctx.attr.abi,
                "api_level": ctx.attr.api_level,
                "embedding": ctx.attr.embedding,
            })
            manifest.append({
                "name": name,
                "reasons": [],
                "strategy": "recipe:{}%{}".format(recipe["bzl"], recipe["macro"]),
                "coordinates": [],
                "is_plugin": False,
            })

    # The Maven coordinates every plugin needs, as a MODULE.bazel segment.
    #
    # These cannot be injected into maven.install() from here: MODULE.bazel is
    # not allowed to load() and an extension cannot add tags to another
    # extension. So the segment is generated, committed, and include()d, and
    # //app:plugins_check diffs the two -- the same shape as pub_path_deps_check,
    # for the same reason: the manual step is exactly the one people skip.
    #
    # It joins the *existing* @flutter_maven install rather than a repo of its
    # own. Multiple install tags with one name merge into a single resolution,
    # so a plugin and the embedding asking for different androidx versions is
    # settled once, instead of shipping both to the dexer.
    ctx.file(
        "plugin_deps.MODULE.bazel",
        _module_segment(
            FLUTTER_EMBEDDING_ARTIFACTS + all_coordinates + ctx.attr.extra_artifacts,
            ctx.attr.maven_resolver,
            ctx.attr.maven_lock_file,
        ),
    )

    ctx.file(
        "dart_plugin_registrant.dart",
        _DART_REGISTRANT_TEMPLATE.format(
            imports = "".join([
                "import 'package:{n}/{f}' as {n};\n".format(n = n, f = f)
                for n, _, f in dart_registrations
            ]),
            registrations = "".join([
                _DART_REGISTRATION.format(name = n, dart_class = c)
                for n, c, _ in dart_registrations
            ]),
        ),
    )

    # The one place the chosen strategy per plugin is recorded.
    ctx.file("plugins.json", json.encode({"plugins": manifest}))

    # Two aggregates, so the app depends on "every plugin" and "every native
    # library a recipe contributed" rather than on hand-maintained lists that
    # have to be edited in lockstep with pubspec.yaml.
    #
    # They are separate because their members differ: `:all` is an
    # android_library and can only export Java/Kotlin targets, while a recipe for
    # a non-plugin package -- sqlite3 -- has no such target to export and
    # contributes only a .so.
    ctx.file(
        "BUILD.bazel",
        _BUILD_HEADER +
        _NATIVE_LIBS_LOADS.format(recipe = ctx.attr.recipe_bzl) +
        "exports_files([\"plugin_deps.MODULE.bazel\", \"plugins.json\", \"dart_plugin_registrant.dart\"])\n\n" +
        "android_library(\n    name = \"all\",\n    exports = [{}\n    ],\n)\n".format(
            "".join([
                "\n        \"//{n}:{n}\",".format(n = p["name"])
                for p in manifest
                if p["is_plugin"]
            ]),
        ) +
        _NATIVE_LIBS_TEMPLATE.format(
            abi = ctx.attr.abi,
            deps = "".join([
                "\n        \"//{n}:{n}_flutter_native\",".format(n = p["name"])
                for p in manifest
                if p["strategy"].startswith("recipe:")
            ]),
        ),
    )


flutter_plugins = repository_rule(
    implementation = _flutter_plugins_impl,
    doc = "One target per native Android Flutter plugin, from .flutter-plugins-dependencies.",
    attrs = {
        "metadata": attr.label(
            doc = "The project's .flutter-plugins-dependencies, written by `pub get`.",
            allow_single_file = True,
            mandatory = True,
        ),
        "embedding": attr.string(
            doc = "Label of the flutter_embedding java_import every plugin compiles against.",
            mandatory = True,
        ),
        "defs": attr.string(
            doc = "Label of //tools/flutter:defs.bzl, for android_native_lib_jar.",
            mandatory = True,
        ),
        "recipe_bzl": attr.string(
            doc = "Label of //tools/flutter:recipe.bzl, for flutter_native_libs.",
            mandatory = True,
        ),
        "package_config": attr.label(
            doc = """The project's .dart_tool/package_config.json.

Only needed to resolve a recipe for a package that is not a Flutter plugin --
.flutter-plugins-dependencies does not list those. Optional so a project with no
such recipe declares nothing extra.""",
            allow_single_file = True,
        ),
        "maven_resolver": attr.string(
            default = "coursier",
            values = ["coursier", "gradle", "maven"],
        ),
        "maven_lock_file": attr.string(),
        "extra_artifacts": attr.string_list(),
        "recipes": attr.string_dict(
            doc = "Package name -> JSON {bzl, macro} naming the recipe to hand generation to.",
        ),
        "abi": attr.string(
            default = "arm64-v8a",
            doc = "Android ABI native plugin code is built for.",
        ),
        "api_level": attr.int(
            default = 21,
            doc = "minSdkVersion CMake builds target; matches the app's manifest_values.",
        ),
        "overrides": attr.string_dict(
            doc = "Package name -> JSON list of Maven coordinates the scraper could not read.",
        ),
    },
    # ANDROID_NDK_HOME selects the NDK *and* its CMake toolchain file, so a
    # change to it has to refetch: the path is baked into the generated BUILD.
    environ = ["ANDROID_NDK_HOME"],
    local = True,
)

_project = tag_class(
    attrs = {
        "metadata": attr.label(
            doc = "The project's .flutter-plugins-dependencies.",
            allow_single_file = True,
            mandatory = True,
        ),
        "package_config": attr.label(
            doc = """The project's .dart_tool/package_config.json.

Required only if a plugins.package() recipe names a package that is not a Flutter
plugin -- a package with a Dart build hook and no android/ module never appears
in .flutter-plugins-dependencies, so there is nothing else to resolve it from.""",
            allow_single_file = True,
        ),
        "extra_artifacts": attr.string_list(
            doc = """Maven coordinates to add to the resolution, attributable to no package.

`plugins.package(artifacts = ...)` covers a coordinate some *plugin* needs. This
covers the rest: an artifact the resolver should have pulled in and did not.

The case it exists for is Kotlin Multiplatform. A KMP module publishes `-android`
and `-jvm` (sometimes `-desktop`) children, and rules_jvm_external's gradle
resolver resolves as a plain JVM consumer, so an Android app silently gets the
wrong one -- `androidx.lifecycle:lifecycle-runtime` resolves to
`lifecycle-runtime-desktop`, which has no `ReportFragment`, and the app compiles
cleanly then dies on launch with NoClassDefFoundError. Naming the `-android`
variant here forces it into the graph. See rules_jvm_external#1605.""",
        ),
        "maven_resolver": attr.string(
            default = "coursier",
            values = ["coursier", "gradle", "maven"],
            doc = """Which resolver settles the Maven graph.

`coursier` (the default) needs no lock file and handles a small graph. A real
app's AndroidX graph needs `gradle`, which is the only resolver that reads Gradle
Module Metadata and so the only one that can satisfy the strict version ranges
AndroidX poms carry -- see docs/package-recipes.md. `gradle` and `maven` both
require `maven_lock_file`.""",
        ),
        "maven_lock_file": attr.string(
            doc = "Label of the maven_install.json lock file, e.g. \"//:maven_install.json\".",
        ),
        "embedding": attr.label(
            default = "@flutter_embedding//jar:file",
            doc = """The `flutter_embedding_library` target every plugin compiles against.

Supplied by the consuming project because the target must live there: its deps
are Maven artifacts resolved from that project's own coordinate list, and a
label naming them from inside these rules would resolve against these rules'
dependencies instead. Instantiate it with
`//tools/flutter:embedding.bzl%flutter_embedding_library` and pass the result
here. The default is the bare engine jar, which compiles but leaves plugins
without androidx.annotation -- enough to fail loudly rather than silently.""",
        ),
    },
)

# The per-package escape hatch, and the only one. Everything a consuming project
# can say about a single pub package is said here.
#
# One tag rather than several because the alternatives -- an `override` for
# coordinates, a `recipe` for build logic, a `replace` for redirection -- are
# three names to learn for one concept. crate_universe's `crate.annotation()`
# takes the same shape for the same reason: one tag, many optional attributes.
#
# The attributes do split, though, and the split is not cosmetic. It follows a
# phase boundary Bazel enforces:
#
#   module/fetch time   `artifacts` feeds the single maven.install, which is
#                       resolved before any BUILD file is loaded.
#   analysis time       `bzl_file`/`macro` name a macro that runs during loading,
#                       long after Maven resolution has finished.
#
# Which is why `artifacts` cannot simply be something a recipe declares: a macro
# runs far too late to add anything to the resolution, and pulling deps from a
# *second* maven.install would resurrect the version-skew bug that the
# single-install rule in _MODULE_SEGMENT_HEADER exists to prevent.
_package = tag_class(
    attrs = {
        "name": attr.string(
            mandatory = True,
            doc = "pub package name. Need not be a Flutter plugin.",
        ),
        "artifacts": attr.string_list(
            doc = """Maven coordinates the scraper could not read statically.

For a BOM-supplied version, or a variable defined outside the plugin's own
build.gradle. Clears the `unresolved_dep` reason for this package.""",
        ),
        "bzl_file": attr.label(
            allow_single_file = [".bzl"],
            doc = """A .bzl in the consuming project holding this package's recipe.

Resolved relative to the module that writes the tag, so its canonical form is
what the generated BUILD loads -- and the recipe's own load() statements then
resolve in that module's repo mapping, not this one's.""",
        ),
        "macro": attr.string(
            doc = "Name of the macro in bzl_file. Called as macro(name, info).",
        ),
    },
)


def _flutter_plugins_ext_impl(ctx):
    overrides = {}
    recipes = {}

    # Dependencies first, then the root module, so the root's entry for a
    # package wins. A dependency may legitimately ship a recipe for something it
    # depends on -- that is why `package` is not restricted to the root the way
    # `project` is -- but the application being built has the final say.
    #
    # Without this, these rules' own demo-app recipes leaked into a consumer's
    # graph and silently replaced theirs: smooth_app declared a `rive_native`
    # recipe, got flutter_bazel's, and failed loading a `@@//tools/flutter`
    # label that does not exist in a consumer's main repo.
    for mod in [m for m in ctx.modules if not m.is_root] + [m for m in ctx.modules if m.is_root]:
        for package in mod.tags.package:
            if package.artifacts:
                overrides[package.name] = json.encode(package.artifacts)
            if package.bzl_file and not package.macro:
                fail("plugins.package(name = \"{}\") gives bzl_file but no macro".format(
                    package.name,
                ))
            if package.macro and not package.bzl_file:
                fail("plugins.package(name = \"{}\") gives macro but no bzl_file".format(
                    package.name,
                ))
            if package.bzl_file:
                recipes[package.name] = json.encode({
                    # Canonical, because the generated repo's repo mapping is
                    # this module's and cannot see the user's apparent names.
                    "bzl": str(package.bzl_file),
                    "macro": package.macro,
                })

    # `project` is honoured from the **root module only**, and deliberately.
    #
    # It names a repository (`flutter_plugins`) and describes one application, so
    # a dependency declaring one would both collide on the name and generate the
    # wrong graph. Bazel's own guidance is that only the root module should
    # directly affect repository names. Without this, adding these rules as a
    # bazel_dep fails immediately -- their own demo app's project tag fires
    # alongside the consumer's.
    #
    # `package` tags are *not* restricted this way: they name pub packages, not
    # repositories, so a library module may reasonably ship a recipe for a
    # package it depends on.
    for mod in ctx.modules:
        if not mod.is_root:
            continue
        for project in mod.tags.project:
            flutter_plugins(
                name = "flutter_plugins",
                metadata = project.metadata,
                package_config = project.package_config,
                extra_artifacts = project.extra_artifacts,
                maven_resolver = project.maven_resolver,
                maven_lock_file = project.maven_lock_file,
                overrides = overrides,
                recipes = recipes,
                # The embedding label comes from the root module; defs and
                # recipe_bzl are resolved here, in the module that owns them, so
                # the generated repository does not have to reason about repo
                # mapping to find them.
                embedding = str(project.embedding),
                defs = str(Label("//tools/flutter:defs.bzl")),
                recipe_bzl = str(Label("//tools/flutter:recipe.bzl")),
            )


flutter_plugins_ext = module_extension(
    implementation = _flutter_plugins_ext_impl,
    tag_classes = {"project": _project, "package": _package},
)
