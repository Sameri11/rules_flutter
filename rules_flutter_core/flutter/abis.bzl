"""The public names of the Android ABI table.

The table itself is in flutter/private/abis.bzl. Its ABI names are the public
spelling of an Android ABI; these are the names the Android module and consumers
read. Engine and embedding repository names, CPU constraints and AOT modes stay
core-private.
"""

load(
    "//flutter/private:abis.bzl",
    _ABIS = "ABIS",
    _ABI_PLATFORM_ATTRS = "ABI_PLATFORM_ATTRS",
    _MODES = "MODES",
    _abi_from_platform = "abi_from_platform",
    _embedding_jar_label = "embedding_jar_label",
    _engine_jar_label = "engine_jar_label",
)

visibility("public")

# The build modes, `release` and `debug`.
MODES = _MODES

# ABI name -> the ABI's per-architecture fields. The keys are the public spelling.
ABIS = _ABIS

# Implicit attributes a rule carries to name its target platform's ABI.
ABI_PLATFORM_ATTRS = _ABI_PLATFORM_ATTRS

# The ABI a rule's target platform selects, or None when it is not a known Android ABI.
abi_from_platform = _abi_from_platform

# The prebuilt engine jar for one ABI and mode, as a Label.
engine_jar_label = _engine_jar_label

# The Java embedding jar for one mode, as a Label.
embedding_jar_label = _embedding_jar_label
