"""The app's pubspec, as one target every other rule reads its facts from.

One fact per file, deliberately: consumers depend only on the fact they use.
The package name, build name and build number travel by provider; asset and
font declarations remain inputs to `flutter build bundle`.
"""

visibility(["//flutter"])

FlutterPubspecInfo = provider(
    doc = "Facts read out of an app's pubspec.yaml.",
    fields = {
        "src": "The pubspec.yaml itself, for tools that parse it in full.",
        "package_name": "File holding the Dart package name.",
        "build_name": "File holding Flutter's build name.",
        "build_number": "File holding Flutter's build number.",
    },
)

def _flutter_pubspec_impl(ctx):
    name = ctx.actions.declare_file(ctx.label.name + "/package_name")
    build_name = ctx.actions.declare_file(ctx.label.name + "/build_name")
    build_number = ctx.actions.declare_file(ctx.label.name + "/build_number")

    args = ctx.actions.args()

    # run_shell reserves $0, so the script arrives as $1 and "$@" includes it.
    args.add(ctx.file._reader)
    args.add("--pubspec", ctx.file.src)
    args.add("--name-out", name)
    args.add("--build-name-out", build_name)
    args.add("--build-number-out", build_number)

    # No env: this action reads one file and writes three, so its key carries no
    # machine-specific path and it can be served from a shared cache.
    ctx.actions.run_shell(
        command = 'exec python3 "$@"',
        arguments = [args],
        inputs = [ctx.file.src, ctx.file._reader],
        outputs = [name, build_name, build_number],
        mnemonic = "FlutterPubspec",
        progress_message = "Reading %{label}",
    )

    return [
        DefaultInfo(files = depset([name, build_name, build_number])),
        FlutterPubspecInfo(
            src = ctx.file.src,
            package_name = name,
            build_name = build_name,
            build_number = build_number,
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
            default = "//flutter/private:read_pubspec.py",
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

        flutter_core(name = "app", pub = "@pub", platforms = [platform])

    The defaults live here rather than on the rule's attribute deliberately. A
    label default on a rule resolves in the package that *defines* the rule, so
    `src = "pubspec.yaml"` there means `//flutter/private:pubspec.yaml` for every
    consumer. A macro expands in the caller's package, where the same string
    means what a reader expects.

    Args:
      name: the target name. Defaults to `pubspec`, so consumers can rely on
        `:pubspec` naming an app's facts.
      src: the pubspec. Defaults to `pubspec.yaml` beside the BUILD file.
      **kwargs: visibility, tags.
    """
    _flutter_pubspec(name = name, src = src, **kwargs)
