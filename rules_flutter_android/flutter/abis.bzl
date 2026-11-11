"""Public Android ABI names and the target data mapped from each one.

The ABI spelling is the name consumers use and the name that appears in APKs.
"""

visibility("public")

# Android CPUs recognized but not supported by Flutter's cached engine.
_UNSUPPORTED_ANDROID_CPU_CONSTRAINTS = {
    Label("@platforms//cpu:x86_32"): "x86",
    Label("@platforms//cpu:riscv64"): "riscv64",
}

def _abi(target_platform, engine_dir, maven_artifact, cpu_constraint, snapshot_flags = []):
    return struct(
        target_platform = target_platform,
        engine_dir = engine_dir,
        maven_artifact = maven_artifact,
        cpu_constraint = cpu_constraint,
        snapshot_flags = snapshot_flags,
    )

ABIS = {
    "arm64-v8a": _abi(
        target_platform = "android-arm64",
        engine_dir = {"release": "android-arm64-release"},
        maven_artifact = {"release": "arm64_v8a_release", "debug": "arm64_v8a_debug"},
        cpu_constraint = Label("@platforms//cpu:arm64"),
    ),
    "x86_64": _abi(
        target_platform = "android-x64",
        engine_dir = {"release": "android-x64-release"},
        maven_artifact = {"release": "x86_64_release", "debug": "x86_64_debug"},
        cpu_constraint = Label("@platforms//cpu:x86_64"),
    ),
    "armeabi-v7a": _abi(
        target_platform = "android-arm",
        engine_dir = {"release": "android-arm-release"},
        maven_artifact = {"release": "armeabi_v7a_release", "debug": "armeabi_v7a_debug"},
        cpu_constraint = Label("@platforms//cpu:armv7"),
        # Keep gen_snapshot output compatible with Flutter's armv7 engine ABI.
        snapshot_flags = ["--no-sim-use-hardfp", "--no-use-integer-division"],
    ),
}

def _abi_cpu_constraints():
    constraints = {entry.cpu_constraint: abi for abi, entry in ABIS.items()}
    for constraint, name in _UNSUPPORTED_ANDROID_CPU_CONSTRAINTS.items():
        if constraint in constraints:
            fail("ABIS and unsupported Android CPUs both name {}.".format(constraint))
        constraints[constraint] = name
    return constraints

ABI_PLATFORM_ATTRS = {
    "_cpu_constraints": attr.label_keyed_string_dict(default = _abi_cpu_constraints()),
    "_android_os": attr.label(default = Label("@platforms//os:android")),
}

def abi_from_platform(ctx):
    """Return the supported/unsupported Android ABI name or None for other OSes.

    Args:
      ctx: The rule context whose target platform is being inspected.

    Returns:
      The ABI name, or None when the platform is not a supported Android ABI.
    """
    android = ctx.attr._android_os[platform_common.ConstraintValueInfo]
    if not ctx.target_platform_has_constraint(android):
        return None
    for target, name in ctx.attr._cpu_constraints.items():
        if ctx.target_platform_has_constraint(target[platform_common.ConstraintValueInfo]):
            return name
    return None
