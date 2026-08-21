"""The app's pubspec, as one target every other rule reads its facts from.

pubspec.yaml holds several facts the build needs -- the package name that makes
a `package:` URI resolvable, the version Android publishes as versionCode and
versionName, and the asset and font declarations `flutter build bundle` reads.
Before this they were spelled out again in BUILD files, where a rename in the
pubspec left them stale and the failure was silent: a mismatched package URI
compiles in and changes nothing.

So a consumer names the pubspec once, and the facts travel by provider.

**One fact per file, deliberately.** Downstream actions depend on the file
holding the fact they use, not on pubspec.yaml, so a version bump does not
invalidate the kernel -- Bazel keys an action on the content of its inputs, and
the package-name file is unchanged.
"""

FlutterPubspecInfo = provider(
    doc = "Facts read out of an app's pubspec.yaml.",
    fields = {
        "src": "The pubspec.yaml itself, for tools that parse it in full.",
        "package_name": "File holding the Dart package name.",
        "version_name": "File holding the version's name part.",
        "version_code": "File holding the version's build number.",
    },
)

def _flutter_pubspec_impl(ctx):
    name = ctx.actions.declare_file(ctx.label.name + "/package_name")
    version_name = ctx.actions.declare_file(ctx.label.name + "/version_name")
    version_code = ctx.actions.declare_file(ctx.label.name + "/version_code")

    args = ctx.actions.args()

    # run_shell reserves $0, so the script arrives as $1 and "$@" includes it.
    args.add(ctx.file._reader)
    args.add("--pubspec", ctx.file.src)
    args.add("--name-out", name)
    args.add("--version-name-out", version_name)
    args.add("--version-code-out", version_code)

    # No env: this action reads one file and writes three, so its key carries no
    # machine-specific path and it can be served from a shared cache.
    ctx.actions.run_shell(
        command = 'exec python3 "$@"',
        arguments = [args],
        inputs = [ctx.file.src, ctx.file._reader],
        outputs = [name, version_name, version_code],
        mnemonic = "FlutterPubspec",
        progress_message = "Reading %{label}",
    )

    return [
        DefaultInfo(files = depset([name, version_name, version_code])),
        FlutterPubspecInfo(
            src = ctx.file.src,
            package_name = name,
            version_name = version_name,
            version_code = version_code,
        ),
    ]

_flutter_pubspec = rule(
    implementation = _flutter_pubspec_impl,
    doc = "Implementation of flutter_pubspec; call the macro, which carries the defaults.",
    attrs = {
        "src": attr.label(
            allow_single_file = [".yaml"],
            mandatory = True,
            doc = "The app's pubspec.yaml.",
        ),
        "_reader": attr.label(
            default = "//tools/flutter:read_pubspec.py",
            allow_single_file = True,
        ),
    },
)

# buildifier: disable=function-docstring-args
def flutter_pubspec(name = "pubspec", src = "pubspec.yaml", **kwargs):
    """An app's pubspec.yaml, with its facts split one per file.

    Both arguments default, because both have exactly one right answer: pub
    mandates the filename `pubspec.yaml`, and an app has one pubspec. So the
    usual declaration carries no information and is written without arguments:

        flutter_pubspec()

        flutter_aot_library(name = "app", pubspec = ":pubspec", ...)
        flutter_assets(name = "assets", pubspec = ":pubspec", ...)
        flutter_android_binary(name = "demo_app", pubspec = "//app:pubspec", ...)

    The defaults live here rather than on the rule's attribute deliberately. A
    label default on a rule resolves in the package that *defines* the rule, so
    `src = "pubspec.yaml"` there means `//tools/flutter:pubspec.yaml` for every
    consumer. A macro expands in the caller's package, where the same string
    means what a reader expects.

    Args:
      name: the target name. Defaults to `pubspec`, so consumers can rely on
        `:pubspec` naming an app's facts.
      src: the pubspec. Defaults to `pubspec.yaml` beside the BUILD file.
      **kwargs: visibility, tags.
    """
    _flutter_pubspec(name = name, src = src, **kwargs)
