"""Maven dependencies of the Flutter Android embedding.

These are declared in the flutter_embedding POM and Gradle resolves them
transitively. `http_jar` fetches only the jar, so they are listed explicitly.
Without them FlutterActivity fails to load at runtime -- androidx.lifecycle.
LifecycleOwner is one of its supertypes, and the resulting error names
FlutterActivity rather than the missing supertype.

This list lives in tools/ rather than beside the app because plugins compile
against the embedding too, and the plugin repository rule must not depend on the
layout of whichever app is being built.

**Coordinates, not labels, are the source of truth.** They are read by
//tools/flutter:plugins.bzl, merged with every plugin's Maven dependencies, and
emitted as a single maven.install in the generated plugin_deps.MODULE.bazel.
MODULE.bazel declares no artifacts of its own: two install tags sharing a
repository name merge into one resolution, and whichever came last won
regardless of version, so a plugin could silently downgrade an artifact declared
here.
"""

load("@rules_java//java:defs.bzl", "java_import")
load(":abis.bzl", "embedding_repo")
load(":maven.bzl", "maven_label")

_MODE_DEBUG = Label("//tools/flutter:mode_debug")
_MODE_RELEASE = Label("//tools/flutter:mode_release")

FLUTTER_EMBEDDING_ARTIFACTS = [
    "androidx.lifecycle:lifecycle-common:2.7.0",
    "androidx.lifecycle:lifecycle-common-java8:2.7.0",
    "androidx.lifecycle:lifecycle-process:2.7.0",
    "androidx.lifecycle:lifecycle-runtime:2.7.0",
    "androidx.fragment:fragment:1.7.1",
    "androidx.annotation:annotation:1.8.1",
    "androidx.tracing:tracing:1.2.0",
    "androidx.core:core:1.13.1",
    "androidx.window:window-java:1.2.0",
    # window-java is only the interop wrapper; WindowMetricsCalculator, which
    # the embedding desugars against, lives in the core artifact.
    "androidx.window:window:1.2.0",
    "androidx.exifinterface:exifinterface:1.4.1",
    "com.getkeepsafe.relinker:relinker:1.4.5",
]

# Targets that exist in the resolved repository without being declared above,
# because something else pulls them in transitively.
#
# androidx.annotation became a KMP module at 1.7: the declared artifact is
# metadata-only and carries no class files. It satisfies runtime resolution (its
# pom points at annotation-jvm) but not a strict compile classpath, and @NonNull
# is on essentially every FlutterPlugin method, so anything compiling against
# the embedding needs the jvm artifact.
_TRANSITIVE_DEPS = ["//:androidx_annotation_annotation_jvm"]

def flutter_embedding_deps(maven_repo = "@flutter_maven"):
    """Labels of the embedding's AndroidX dependencies in `maven_repo`.

    A function of the repository rather than a constant, because the repository
    belongs to the *consuming* project: its coordinate list is that project's
    plugins merged with these, so it is created by that project's MODULE.bazel
    and is not visible from inside these rules. See flutter_embedding_library.
    """
    return [
        maven_label(coordinate, repo = maven_repo)
        for coordinate in FLUTTER_EMBEDDING_ARTIFACTS
    ] + [maven_repo + dep for dep in _TRANSITIVE_DEPS]

def flutter_embedding_library(name = "flutter_embedding", maven_repo = "@flutter_maven"):
    """The engine jar re-imported with its AndroidX dependencies attached.

    **Instantiated by the consuming project, not by these rules**, because its
    deps live in a Maven repository the consumer's MODULE.bazel creates. A macro
    here and a target there is the only arrangement that works: a label like
    `@flutter_maven//:x` written inside this module would resolve against *this*
    module's dependencies, so a consumer would silently compile against whatever
    Maven graph these rules happen to declare for their own demo app.

    The AndroidX deps are `exports`, not just `deps`. Gradle attaches the
    embedding to every plugin as an *api* dependency precisely so its API
    surface propagates -- `FlutterPlugin` annotates its methods with androidx
    @NonNull, so a plugin cannot compile against the embedding without also
    seeing androidx.annotation. Bazel does not re-export `deps` to a consumer's
    compile classpath, so without this every plugin target fails Turbine with
    "symbol not found androidx.annotation.NonNull".

    Desugaring resolves supertypes per-target, which is why the deps hang here,
    on the target that holds the classes, rather than on android_binary: with
    them only there, singlejar fails with "WindowMetricsCalculator needed on the
    classpath for desugaring io/flutter/util/ViewUtils".
    """
    deps = flutter_embedding_deps(maven_repo)
    java_import(
        name = name,
        # Engine jars resolve here; Maven dependencies resolve in the consumer.
        jars = select({
            _MODE_DEBUG: [Label("@{}//jar:file".format(embedding_repo("debug")))],
            _MODE_RELEASE: [Label("@{}//jar:file".format(embedding_repo("release")))],
        }),
        deps = deps,
        exports = deps,
        visibility = ["//visibility:public"],
    )
