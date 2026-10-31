"""The Android SDK as a native build environment.

flutter_app and flutter_core run an app's native build hooks through
`flutter build`. Those hooks find the SDK through ANDROID_HOME, so this rule
exports it for the action that runs them.
"""

load("@rules_flutter_core//flutter:defs.bzl", "FlutterNativeBuildEnvInfo")

def _native_build_env_impl(ctx):
    sdk = ctx.file._android_sdk
    exports = """export ANDROID_HOME="$(python3 -c 'import os, sys; print(os.path.dirname(os.path.dirname(os.path.realpath(sys.argv[1]))))' "$EXECROOT/{android_sdk}")"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
""".format(android_sdk = sdk.path)
    return [FlutterNativeBuildEnvInfo(exports = exports, files = depset([sdk]))]

native_build_env = rule(
    implementation = _native_build_env_impl,
    doc = "Exports the Android SDK location to a native build hook.",
    attrs = {
        "_android_sdk": attr.label(
            default = "//flutter/private:_android_sdk_marker",
            allow_single_file = True,
            cfg = "exec",
        ),
    },
)
