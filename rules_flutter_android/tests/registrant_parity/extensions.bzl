"""Renders the Android registrant for each registrant parity case.

A dev-only extension: the case hubs it reads are dev-only pub locks in MODULE.bazel,
so a consumer that depends on this module never evaluates either.
"""

load(":registrant.bzl", "registrant_parity_android")

# Each case's pub hub is declared in MODULE.bazel as registrant_parity_<case>.
_CASES = (
    "federated_default",
    "federated_dev_override",
    "federated_direct",
    "mixed",
    "no_plugins",
)

# The hub names are fixed in MODULE.bazel, so the extension reads nothing from module_ctx.
# buildifier: disable=unused-variable
def _registrant_parity_impl(module_ctx):
    for case in _CASES:
        hub = "@registrant_parity_" + case
        registrant_parity_android(
            name = "registrant_parity_{}_android".format(case),
            metadata = hub + "//:plugins_metadata.json",
            package_config = hub + "//:package_config.json",
        )

registrant_parity = module_extension(
    implementation = _registrant_parity_impl,
)
