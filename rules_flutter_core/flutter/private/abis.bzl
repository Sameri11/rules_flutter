"""Mode values and compatibility selects for core Flutter rules."""

visibility(["//flutter", "//flutter/private"])

MODES = ["release", "debug"]
AOT_MODES = ["release"]

def aot_target_compatible_with():
    """target_compatible_with for a rule that only runs under an AOT-capable mode."""
    conditions = {"//conditions:default": [Label("@platforms//:incompatible")]}
    for mode in AOT_MODES:
        conditions[Label("//flutter:mode_" + mode)] = []
    return select(conditions)

def debug_target_compatible_with():
    """target_compatible_with for a rule that exists only in debug mode."""
    return select({
        Label("//flutter:mode_debug"): [],
        "//conditions:default": [Label("@platforms//:incompatible")],
    })
