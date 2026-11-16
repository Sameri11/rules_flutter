#!/usr/bin/env bash
set -euo pipefail

has_lib=0
for path in "$@"; do
  case "$path" in
    */lib/*) has_lib=1 ;;
  esac
  case "$path" in
    */.git/*|*/.git) echo "unexpected .git path: $path" >&2; exit 1 ;;
  esac
done
if [[ "$has_lib" != 1 ]]; then
  echo "git package file set does not contain lib/" >&2
  exit 1
fi
