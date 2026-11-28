"""Runnable developer CLIs backed by the provisioned Flutter SDK."""

def _dev_tool_impl(ctx):
    launcher = ctx.actions.declare_file(ctx.label.name + ".sh")
    marker_key = "flutter_dev_tools/" + ctx.label.name + ".version.json"
    script = """#!/usr/bin/env bash
set -euo pipefail
runfiles_dir="${RUNFILES_DIR:-$0.runfiles}"
marker="$runfiles_dir/_main/%s"
if [[ ! -e "$marker" ]]; then
  echo "Flutter SDK runfile is missing: $marker" >&2
  exit 1
fi
target="$(readlink "$marker")"
if [[ "$target" = /* ]]; then
  marker="$target"
else
  marker="$(dirname "$marker")/$target"
fi
sdk_root="$(cd "$(dirname "$marker")" && pwd -P)"
workdir="${BUILD_WORKING_DIRECTORY:-${BUILD_WORKSPACE_DIRECTORY:?Bazel run workspace is unset}}"
cd "$workdir"
export FLUTTER_ROOT="$sdk_root"
if [[ "%s" == "link" ]]; then
  link="$workdir/.fvm/flutter_sdk"
  mkdir -p "$(dirname "$link")"
  if [[ -e "$link" || -L "$link" ]]; then
    if [[ ! -L "$link" ]]; then
      echo "Refusing to replace non-symlink SDK path: $link" >&2
      exit 1
    fi
    rm "$link"
  fi
  ln -s "$sdk_root" "$link"
  echo "$link -> $sdk_root"
  exit 0
fi
exec "$sdk_root/%s" "$@"
""" % (marker_key, ctx.attr.tool, ctx.attr.tool)
    ctx.actions.write(launcher, script, is_executable = True)
    return DefaultInfo(
        executable = launcher,
        runfiles = ctx.runfiles(symlinks = {marker_key: ctx.file._sdk_version}),
    )

dev_tool = rule(
    implementation = _dev_tool_impl,
    attrs = {
        "tool": attr.string(mandatory = True, values = ["dart", "bin/flutter", "link"]),
        "_sdk_version": attr.label(
            default = Label("@flutter_sdk//:flutter.version.json"),
            allow_single_file = True,
        ),
    },
    executable = True,
)
