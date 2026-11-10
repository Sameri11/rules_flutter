"""Public descriptor for the second consumer-test platform."""

load("@rules_flutter_core//flutter:defs.bzl", "flutter_platform")

FLUTTER_FAKE = flutter_platform(
    name = "fake",
    target_platforms = [Label("//fake_platform:fake_target")],
    constraint = Label("//fake_platform:fake_os_value"),
)
