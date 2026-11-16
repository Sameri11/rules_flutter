#!/usr/bin/env bash
set -euo pipefail

has_lib=0
for path in "$@"; do
  case "$path" in
    */lib/*)
      has_lib=1
      package_root="${path%%/lib/*}"
      if [[ -e "$package_root/.git" || -e "$package_root/_git" ]]; then
        echo "git metadata remains in fetched package: $package_root" >&2
        exit 1
      fi
      ;;
  esac
done
if [[ "$has_lib" != 1 ]]; then
  echo "git package file set does not contain lib/" >&2
  exit 1
fi
