"""Produces a deterministic executable stand-in for gen_snapshot."""

_FAKE_SNAPSHOT = """#!/usr/bin/env bash
set -eu
output=""
for arg in "$@"; do
  case "$arg" in
    --assembly=*) output=${arg#--assembly=} ;;
  esac
done
if [ -z "$output" ]; then
  echo "expected --assembly=<output>" >&2
  exit 1
fi
printf '.text\\n.globl fake_flutter_aot\\nfake_flutter_aot:\\n' > "$output"
"""

def _fake_gen_snapshot_impl(ctx):
    output = ctx.actions.declare_file(ctx.label.name)
    ctx.actions.write(output = output, content = _FAKE_SNAPSHOT, is_executable = True)
    return [DefaultInfo(executable = output, files = depset([output]))]

fake_gen_snapshot = rule(
    implementation = _fake_gen_snapshot_impl,
    executable = True,
)
