"""Repository rule exposing a Flutter SDK's build tools as Bazel targets.

This locates an *existing* Flutter SDK (via the FLUTTER_ROOT env var, or by
resolving the `flutter` binary on PATH) and symlinks the handful of artifacts
the build actually needs. It deliberately does not download the SDK: Flutter's
artifacts are fetched lazily by `flutter precache`, so a fully hermetic
download rule is a separate concern. See README for that tradeoff.
"""

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_jar")
load(":abis.bzl", "ABIS", "AOT_MODES", "MODES", "embedding_repo", "engine_repo")

_BUILD_TEMPLATE = """
package(default_visibility = ["//visibility:public"])

# Binaries and the frontend_server snapshot are referenced as files directly.
# They are deliberately not wrapped in filegroups: a filegroup sharing a name
# with the file it wraps produces a self-edge in the dependency graph.
exports_files([
    "dartaotruntime",
    "flutter",
    "frontend_server.snapshot",
    "flutter.version.json",
] + {gen_snapshots})

# Patched SDK containing platform_strong.dill. `--sdk-root` wants the directory,
# so the whole tree is exposed as one filegroup.
filegroup(
    name = "platform_product",
    srcs = glob(["flutter_patched_sdk_product/**"]),
)

filegroup(
    name = "platform_debug",
    srcs = glob(["flutter_patched_sdk/**"]),
)
"""

_HOST_ARCHES = {
    "aarch64": "arm64",
    "amd64": "x64",
    "arm64": "arm64",
    "riscv64": "riscv64",
    "x86_64": "x64",
}

def _host_platform_name(ctx):
    """The engine's name for this host, e.g. `darwin-arm64` or `linux-x64`."""
    name = ctx.os.name.lower()
    if name.startswith("mac os"):
        host_os = "darwin"
    elif name.startswith("linux"):
        host_os = "linux"
    elif name.startswith("windows"):
        host_os = "windows"
    else:
        fail("Unsupported host OS for a Flutter build: '{}'.".format(ctx.os.name))

    arch = _HOST_ARCHES.get(ctx.os.arch.lower())
    if arch == None:
        fail("Unsupported host architecture for a Flutter build: '{}'.".format(ctx.os.arch))

    return "{}-{}".format(host_os, arch)

def _gen_snapshot_host_dir(ctx):
    """Host directory holding the Android gen_snapshot."""

    # TODO(flutter/flutter#152281): delete the collapse and return
    # _host_platform_name(ctx) directly, once the engine ships an arm64-native
    # Android gen_snapshot.
    host = _host_platform_name(ctx)
    return "darwin-x64" if host.startswith("darwin-") else host

def _resolve_flutter_root(ctx):
    """Locate the SDK from FLUTTER_ROOT, else from `flutter` on PATH.

    Shared by the repository rule and the module extension; both `repository_ctx`
    and `module_ctx` expose the `os` and `which` members this uses.
    """
    root = ctx.os.environ.get("FLUTTER_ROOT", "").strip()
    if root:
        return root

    flutter = ctx.which("flutter")
    if flutter == None:
        fail(
            "Could not locate a Flutter SDK. Set FLUTTER_ROOT, or put " +
            "`flutter` on PATH.",
        )

    # `flutter` on PATH is usually a shim (fvm, asdf) whose parent is
    # <sdk>/bin, so walk up one level from the resolved binary.
    return str(flutter.realpath.dirname.dirname)

def _flutter_sdk_impl(ctx):
    root = _resolve_flutter_root(ctx)
    cache = "{}/bin/cache".format(root)
    engine = "{}/artifacts/engine".format(cache)

    # Fail early with a useful message rather than a broken symlink later.
    if not ctx.path(engine).exists:
        fail(
            "Flutter engine artifacts missing at {}.\n".format(engine) +
            "Run `flutter precache --android` first.",
        )

    ctx.symlink(
        "{}/dart-sdk/bin/dartaotruntime".format(cache),
        "dartaotruntime",
    )

    # Declared as an input so the action key hashes the launcher's content,
    # not this machine's SDK path.
    ctx.symlink(
        "{}/bin/flutter".format(root),
        "flutter",
    )
    ctx.symlink(
        "{}/dart-sdk/bin/snapshots/frontend_server_aot.dart.snapshot".format(cache),
        "frontend_server.snapshot",
    )
    ctx.symlink(
        "{}/common/flutter_patched_sdk_product".format(engine),
        "flutter_patched_sdk_product",
    )

    # Debug kernels compile against the non-product patched SDK (asserts and
    # service protocol retained).
    ctx.symlink(
        "{}/common/flutter_patched_sdk".format(engine),
        "flutter_patched_sdk",
    )

    # Create a snapshot symlink for each ABI and AOT mode.
    host = _gen_snapshot_host_dir(ctx)
    for abi, info in ABIS.items():
        for mode in AOT_MODES:
            gen_snapshot = "{}/{}/{}/gen_snapshot".format(engine, info.engine_dir[mode], host)

            if not ctx.path(gen_snapshot).exists:
                fail(
                    "gen_snapshot for {} missing at {}.\n".format(abi, gen_snapshot) +
                    "Run `flutter precache --android` on this host.",
                )
            ctx.symlink(gen_snapshot, "gen_snapshot_{}_{}".format(abi, mode))

    # Identity of the *active* SDK: frameworkRevision is a git commit hash, so
    # it moves on framework-only commits that leave engine artifacts identical.
    # Not to be confused with a project's .metadata, which records the revision
    # the project was scaffolded with and is never updated by ordinary SDK use.
    ctx.symlink(
        "{}/flutter.version.json".format(cache),
        "flutter.version.json",
    )

    ctx.file("BUILD.bazel", _BUILD_TEMPLATE.format(
        gen_snapshots = repr([
            "gen_snapshot_{}_{}".format(abi, mode)
            for abi in ABIS
            for mode in AOT_MODES
        ]),
    ))

    # FlutterAssets includes this environment in its action key. Keep portable
    # values fixed; --no-pub does not need PUB_CACHE, and the action sets HOME.
    env = {
        # Bazel's own default action PATH, which every rule here that sets no
        # env already gets. Fixed rather than inherited: the ambient value was
        # the sole cause of a measured cross-machine cache miss.
        "PATH": "/bin:/usr/bin:/usr/local/bin",
        # Flutter's SDK-scoped lock protects its pre-cached artifacts. The
        # action only reads them and runs with --no-pub.
        "FLUTTER_ALREADY_LOCKED": "true",
    }

    # Dart build hooks require an Android SDK; accept either conventional name.
    for optional in ["ANDROID_HOME", "ANDROID_SDK_ROOT"]:
        value = ctx.os.environ.get(optional, "")
        if value:
            env[optional] = value

    ctx.file(
        "sdk.bzl",
        "FLUTTER_ENV = {env}\n".format(env = repr(env)),
    )

flutter_sdk = repository_rule(
    implementation = _flutter_sdk_impl,
    doc = "Exposes the pinned Flutter SDK's compiler + snapshotter to Bazel.",
    local = True,
    # PATH is needed when FLUTTER_ROOT is unset. HOME and PUB_CACHE are not read.
    environ = ["FLUTTER_ROOT", "PATH", "ANDROID_HOME", "ANDROID_SDK_ROOT"],
)

# The Android embedding is not in bin/cache -- Flutter fetches it from Maven at
# Gradle time. The URLs are derivable from flutter.version.json, with one trap:
# the *directory* is versioned by engineRevision while the *filename* uses
# engineContentHash, and the artifacts are .jar, not .aar.
_ENGINE_BASE = "https://storage.googleapis.com/download.flutter.io/io/flutter"

# Builds mode-specific embedding artifact URLs.

def _engine_url(artifact, revision, content_hash):
    return "{base}/{a}/1.0.0-{rev}/{a}-1.0.0-{hash}.jar".format(
        base = _ENGINE_BASE,
        a = artifact,
        rev = revision,
        hash = content_hash,
    )

def _flutter_impl(ctx):
    flutter_sdk(name = "flutter_sdk")

    # Deriving these from the pinned SDK keeps the engine artifacts in lockstep
    # with it: bumping the SDK changes both hashes, hence both URLs.
    root = _resolve_flutter_root(ctx)
    version = json.decode(ctx.read("{}/bin/cache/flutter.version.json".format(root)))
    revision = version["engineRevision"]
    content_hash = version["engineContentHash"]

    # No sha256 on any of these: the URL already embeds engineContentHash, so it
    # is content-addressed by construction, and pinning a digest would have to be
    # re-edited on every SDK bump.
    for mode in MODES:
        http_jar(
            name = embedding_repo(mode),
            url = _engine_url("flutter_embedding_" + mode, revision, content_hash),
        )
    for abi, info in ABIS.items():
        for mode in MODES:
            http_jar(
                name = engine_repo(abi, mode),
                url = _engine_url(info.maven_artifact[mode], revision, content_hash),
            )

flutter = module_extension(implementation = _flutter_impl)
