#!/bin/bash
# Runs the device parity check for one fixture; see device_parity.py.
#
# Args: <device_parity.py> <dart> <decoder> <host launcher> <device launcher>
# <expected>, as rlocationpaths, then the check's flags.
set -euo pipefail
ROOT="${TEST_SRCDIR:?TEST_SRCDIR is not set}"

exec python3 "$ROOT/$1" \
    --dart "$ROOT/$2" \
    --decoder "$ROOT/$3" \
    --host "$ROOT/$4" \
    --device "$ROOT/$5" \
    --expected "$ROOT/$6" \
    --tmp "$TEST_TMPDIR" \
    "${@:7}"
