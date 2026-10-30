#!/bin/bash
# Runs one fixture's launcher and checks it against the fixture's expected file.
#
# Args: <launcher> <expected> <check.py>, as rlocationpaths.
set -euo pipefail
ROOT="${TEST_SRCDIR:?TEST_SRCDIR is not set}"

# Clear the outer run's filter and shard variables: each expected run sets its
# own. The launcher's JUnit goes to its own file, not this test's XML_OUTPUT_FILE.
unset TESTBRIDGE_TEST_ONLY TEST_TOTAL_SHARDS TEST_SHARD_INDEX TEST_SHARD_STATUS_FILE TEST_PREMATURE_EXIT_FILE
export XML_OUTPUT_FILE="$TEST_TMPDIR/inner.xml"

exec python3 "$ROOT/$3" --launcher "$ROOT/$1" --expected "$ROOT/$2" --tmp "$TEST_TMPDIR"
