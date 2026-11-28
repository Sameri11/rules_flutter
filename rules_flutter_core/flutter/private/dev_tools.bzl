"""Executable developer tools from the registered Flutter SDK."""

visibility(["//flutter"])

_TOOLCHAIN = "//flutter/private:flutter_toolchain_type"


def _dev_tool_impl(ctx):
    toolchain = ctx.toolchains[_TOOLCHAIN].flutter
    launcher = ctx.actions.declare_file(ctx.label.name + ".sh")
    sdk_marker = "flutter_dev_tools/sdk_version.json"
    dart_key = "flutter_dev_tools/dart"
    snapshot_key = "flutter_dev_tools/flutter_tools.snapshot"
    package_config_key = "flutter_dev_tools/flutter_tools_package_config.json"
    script = """#!/usr/bin/env bash
set -euo pipefail
runfiles_dir="${{RUNFILES_DIR:-$0.runfiles}}"
sdk_marker="$runfiles_dir/_main/{sdk_marker}"
dart="$runfiles_dir/_main/{dart_key}"
snapshot="$runfiles_dir/_main/{snapshot_key}"
package_config="$runfiles_dir/_main/{package_config_key}"
if [[ ! -e "$sdk_marker" || ! -e "$dart" ]]; then
  echo "Flutter SDK runfiles are missing" >&2
  exit 1
fi
sdk_version="$(readlink "$sdk_marker")"
if [[ "$sdk_version" != /* ]]; then sdk_version="$(dirname "$sdk_marker")/$sdk_version"; fi
sdk_version="$(cd "$(dirname "$sdk_version")" && pwd -P)/$(basename "$sdk_version")"
export FLUTTER_ROOT="$(dirname "$(dirname "$(dirname "$sdk_version")")")"
export FLUTTER_ALREADY_LOCKED=true
if [[ -n "${{BUILD_WORKING_DIRECTORY:-}}" ]]; then cd "$BUILD_WORKING_DIRECTORY"; fi
if [[ "{tool}" == "flutter" ]]; then
  command=""
  args=("$@")
  for ((i = 0; i < ${{#args[@]}}; i++)); do
    if [[ "${{args[$i]}}" == "--" ]]; then
      i=$((i + 1))
      if ((i < ${{#args[@]}})); then command="${{args[$i]}}"; fi
      break
    fi
    if [[ "${{args[$i]}}" != -* ]]; then command="${{args[$i]}}"; break; fi
  done
  case "$command" in
    upgrade|downgrade|channel|precache|update-packages|build)
      echo "flutter $command is unavailable for the Bazel-provisioned SDK; select a version with flutter.sdk(version = …) in MODULE.bazel or use bazel build." >&2
      exit 2
      ;;
  esac
  exec "$dart" --packages="$package_config" "$snapshot" --no-version-check "$@"
fi
exec "$dart" "$@"
"""
    script = script.format(
        sdk_marker = sdk_marker,
        dart_key = dart_key,
        snapshot_key = snapshot_key,
        package_config_key = package_config_key,
        tool = ctx.attr.tool,
    )
    ctx.actions.write(launcher, script, is_executable = True)
    return DefaultInfo(
        executable = launcher,
        runfiles = ctx.runfiles(symlinks = {
            sdk_marker: toolchain.sdk_version,
            dart_key: toolchain.dart,
            snapshot_key: toolchain.tools_snapshot,
            package_config_key: toolchain.tools_package_config,
        }),
    )


dev_tool = rule(
    implementation = _dev_tool_impl,
    attrs = {"tool": attr.string(mandatory = True, values = ["dart", "flutter"])},
    executable = True,
    toolchains = [_TOOLCHAIN],
)
