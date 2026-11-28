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
sdk_root="${FLUTTER_ROOT_OVERRIDE:-$sdk_root}"
export FLUTTER_ROOT="$sdk_root"
if [[ "%s" == "link" ]]; then
  link="$workdir/.fvm/flutter_sdk"
  mkdir -p "$(dirname "$link")"
  if [[ -L "$link" ]]; then
    rm "$link"
  elif [[ -e "$link" ]]; then
    if [[ ! -f "$link/.flutter-dev-tools-managed" ]]; then
      echo "Refusing to replace unmanaged SDK path: $link" >&2
      exit 1
    fi
    rm -rf "$link"
  fi
  mkdir -p "$link/bin"
  touch "$link/.flutter-dev-tools-managed"
  shopt -s dotglob nullglob
  for entry in "$sdk_root"/*; do
    name="${entry##*/}"
    [[ "$name" == "bin" ]] && continue
    ln -s "$entry" "$link/$name"
  done
  for entry in "$sdk_root"/bin/*; do
    name="${entry##*/}"
    [[ "$name" == "cache" || "$name" == "flutter" ]] && continue
    ln -s "$entry" "$link/bin/$name"
  done
  ln -s "$sdk_root/bin/cache" "$link/bin/cache"
  dart="$runfiles_dir/_main/flutter_dev_tools/dart"
  config="$runfiles_dir/_main/flutter_dev_tools/flutter_tools_package_config.json"
  snapshot="$runfiles_dir/_main/flutter_dev_tools/flutter_tools_snapshot.dill"
  for file in "$dart" "$config" "$snapshot"; do
    if [[ ! -e "$file" ]]; then
      echo "Flutter tool runfile is missing: $file" >&2
      exit 1
    fi
  done
  {
    printf '#!/usr/bin/env bash\nset -euo pipefail\n'
    printf 'dart=%%q\nconfig=%%q\nsnapshot=%%q\n' "$dart" "$config" "$snapshot"
    cat <<'FLUTTER_TOOLS_LAUNCHER'
root="$(cd "$(dirname "$0")/.." && pwd -P)"
export FLUTTER_ROOT="$root"
exec "$dart" --packages="$config" "$snapshot" "$@"
FLUTTER_TOOLS_LAUNCHER
  } > "$link/bin/flutter"
  chmod +x "$link/bin/flutter"
  echo "$link -> provisioned SDK $sdk_root with flutter_tools launcher"
  exit 0
fi
if [[ "%s" == "flutter_tools" ]]; then
  exec "$runfiles_dir/_main/flutter_dev_tools/dart" \
    --packages="$runfiles_dir/_main/flutter_dev_tools/flutter_tools_package_config.json" \
    "$runfiles_dir/_main/flutter_dev_tools/flutter_tools_snapshot.dill" "$@"
fi
exec "$sdk_root/%s" "$@"
""" % (marker_key, ctx.attr.tool, ctx.attr.tool, ctx.attr.tool)
    ctx.actions.write(launcher, script, is_executable = True)
    return DefaultInfo(
        executable = launcher,
        runfiles = ctx.runfiles(symlinks = {
            marker_key: ctx.file._sdk_version,
            "flutter_dev_tools/dart": ctx.file._dart,
            "flutter_dev_tools/flutter_tools_snapshot.dill": ctx.file._tools_snapshot,
            "flutter_dev_tools/flutter_tools_package_config.json": ctx.file._tools_package_config,
        }),
    )

dev_tool = rule(
    implementation = _dev_tool_impl,
    attrs = {
        "tool": attr.string(mandatory = True, values = ["dart", "bin/flutter", "link", "flutter_tools"]),
        "_sdk_version": attr.label(
            default = Label("@flutter_sdk//:flutter.version.json"),
            allow_single_file = True,
        ),
        "_dart": attr.label(
            default = Label("@flutter_sdk//:dart"),
            allow_single_file = True,
        ),
        "_tools_snapshot": attr.label(
            default = Label("//flutter/private:flutter_tools_snapshot"),
            allow_single_file = True,
        ),
        "_tools_package_config": attr.label(
            default = Label("@flutter_tools//:package_config.json"),
            allow_single_file = True,
        ),
    },
    executable = True,
)
