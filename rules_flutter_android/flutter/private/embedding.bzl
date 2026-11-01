"""Maven dependencies of the Flutter Android embedding.

These are declared in the flutter_embedding POM and Gradle resolves them
The artifact repository fetches only the jar, so these transitive deps are
listed explicitly.
Without them FlutterActivity fails to load at runtime -- androidx.lifecycle.
LifecycleOwner is one of its supertypes, and the resulting error names
FlutterActivity rather than the missing supertype.

This list lives in tools/ rather than beside the app because plugins compile
against the embedding too, and the plugin repository rule must not depend on the
layout of whichever app is being built.

**Coordinates, not labels, are the source of truth.** They are read by
//flutter/private:plugins.bzl, merged with every plugin's Maven dependencies, and
emitted as a single maven.install in the generated plugin_deps.MODULE.bazel.
MODULE.bazel declares no artifacts of its own: two install tags sharing a
repository name merge into one resolution, and whichever came last won
regardless of version, so a plugin could silently downgrade an artifact declared
here.
"""

load(":maven.bzl", "maven_label")

visibility(["//flutter"])

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
ANNOTATION_JVM = "//:androidx_annotation_annotation_jvm"

_TRANSITIVE_DEPS = [ANNOTATION_JVM]

def flutter_embedding_deps(maven_repo = "@flutter_maven"):
    """Labels of the embedding's AndroidX dependencies in `maven_repo`.

    The consuming module owns the Maven repository, so these labels are resolved
    in its mapping.
    """
    return [
        maven_label(coordinate, repo = maven_repo)
        for coordinate in FLUTTER_EMBEDDING_ARTIFACTS
    ] + [maven_repo + dep for dep in _TRANSITIVE_DEPS]
