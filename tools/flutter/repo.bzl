"""Repository rule exposing a Flutter SDK's build tools as Bazel targets.

This locates an *existing* Flutter SDK (via the FLUTTER_ROOT env var, or by
resolving the `flutter` binary on PATH) and symlinks the handful of artifacts
the build actually needs. It deliberately does not download the SDK: Flutter's
artifacts are fetched lazily by `flutter precache`, so a fully hermetic
download rule is a separate concern. See README for that tradeoff.
"""

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_jar")

_BUILD_TEMPLATE = """
package(default_visibility = ["//visibility:public"])

# Binaries and the frontend_server snapshot are referenced as files directly.
# They are deliberately not wrapped in filegroups: a filegroup sharing a name
# with the file it wraps produces a self-edge in the dependency graph.
exports_files([
    "dartaotruntime",
    "frontend_server.snapshot",
    "gen_snapshot_android_arm64",
    "flutter.version.json",
])

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

    gen_snapshot = "{}/android-arm64-release/{}/gen_snapshot".format(
        engine,
        _gen_snapshot_host_dir(ctx),
    )

    # ctx.symlink creates dangling links silently, which would surface much
    # later as a file-not-found inside the AOT action.
    if not ctx.path(gen_snapshot).exists:
        fail(
            "Android gen_snapshot missing at {}.\n".format(gen_snapshot) +
            "Run `flutter precache --android` on this host.",
        )
    ctx.symlink(gen_snapshot, "gen_snapshot_android_arm64")

    # Identity of the *active* SDK: frameworkRevision is a git commit hash, so
    # it moves on framework-only commits that leave engine artifacts identical.
    # Not to be confused with a project's .metadata, which records the revision
    # the project was scaffolded with and is never updated by ordinary SDK use.
    ctx.symlink(
        "{}/flutter.version.json".format(cache),
        "flutter.version.json",
    )

    ctx.file("BUILD.bazel", _BUILD_TEMPLATE)

    # The `flutter` CLI needs its whole SDK tree to run, so it is invoked by
    # absolute path rather than declared as a Bazel input. That is consistent
    # with these actions already being unsandboxed; invalidation is covered by
    # the version stamps in :flutter.version.json.
    # flutter_tools needs a real environment: it locates the Android SDK by
    # probing $HOME, and resolves packages through $PUB_CACHE. Capturing the
    # specific variables here keeps the action env explicit and recorded, rather
    # than inheriting the whole ambient environment via use_default_shell_env.
    env = {
        "HOME": ctx.os.environ.get("HOME", ""),
        "PATH": ctx.os.environ.get("PATH", ""),
        # The flutter CLI flocks $FLUTTER_ROOT/bin/cache/lockfile on startup, so
        # concurrent invocations serialize regardless of working directory --
        # the lock is SDK-scoped, not project-scoped. flutter_tools sets this
        # same variable for its own sub-invocations (base/process.dart).
        #
        # Safe here because the lock protects the SDK cache from concurrent
        # mutation, and these actions only read it: --no-pub prevents dependency
        # resolution, and the SDK must already be precached.
        "FLUTTER_ALREADY_LOCKED": "true",
    }
    for optional in ["ANDROID_HOME", "ANDROID_SDK_ROOT", "PUB_CACHE"]:
        value = ctx.os.environ.get(optional, "")
        if value:
            env[optional] = value

    ctx.file(
        "sdk.bzl",
        "FLUTTER_ROOT = \"{root}\"\nFLUTTER_BIN = \"{root}/bin/flutter\"\nFLUTTER_ENV = {env}\n".format(
            root = root,
            env = repr(env),
        ),
    )

flutter_sdk = repository_rule(
    implementation = _flutter_sdk_impl,
    doc = "Exposes the pinned Flutter SDK's compiler + snapshotter to Bazel.",
    local = True,
    environ = ["FLUTTER_ROOT", "PATH", "HOME", "ANDROID_HOME", "ANDROID_SDK_ROOT", "PUB_CACHE"],
)

# The Android embedding is not in bin/cache -- Flutter fetches it from Maven at
# Gradle time. The URLs are derivable from flutter.version.json, with one trap:
# the *directory* is versioned by engineRevision while the *filename* uses
# engineContentHash, and the artifacts are .jar, not .aar.
_ENGINE_BASE = "https://storage.googleapis.com/download.flutter.io/io/flutter"

_ENGINE_ARTIFACTS = {
    # repo name -> maven artifact id
    "flutter_engine_arm64": "arm64_v8a_release",
    "flutter_embedding": "flutter_embedding_release",
}

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

    for repo_name, artifact in _ENGINE_ARTIFACTS.items():
        http_jar(
            name = repo_name,
            url = _engine_url(artifact, revision, content_hash),
            # No sha256: the URL already embeds engineContentHash, so it is
            # content-addressed by construction, and pinning a digest here would
            # have to be re-edited on every SDK bump.
        )

flutter = module_extension(implementation = _flutter_impl)
