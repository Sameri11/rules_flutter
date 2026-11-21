"""Expected sha256 of driver.dill, per Flutter version and per toolchain platform dill.

driver.dill links the VM platform, so its bytes depend on the vm_platform_strong.dill the
toolchain provides. The Linux and macOS Flutter archives ship platform dills that differ by one
byte, so the driver differs by one byte between hosts. The key is the sha256 of the platform dill
the test receives, not the host name. For a given platform dill the bytes are reproducible: the
sources are pinned and the build has no checkout paths in argv.

GOLDEN[version][platform_dill_sha256] = driver_dill_sha256.

When the table has no entry for a version and platform, the golden test fails and prints both
sha256 values and the entry to add. After an intended change to the driver's sources or pins,
rebuild the driver and replace its entry the same way. Say in the commit why the bytes changed.
"""

GOLDEN = {
    "3.50.1": {
        # Linux x64 archive.
        "759b896591c197dd3f661fa0d6cfceb6416c31cd062849c18c716fd60b741895": "99a67e825b1c6bd3bb32f99c0aaf5c4bf0adf84b8b315f754a16954479729977",
        # macOS arm64 archive.
        "89e127de48f8b6729ac9e3240a6723851218b5d21999ba841a8dcc22ea3f841a": "af3ea8a18cbcc62cac81c63bd70a62604132e6d1636d64322b19aba06264639d",
    },
}

def golden_entries():
    """Flattens GOLDEN to "version platform_sha256" keys, the form the golden test reads."""
    return {
        version + " " + platform: driver
        for version, by_platform in GOLDEN.items()
        for platform, driver in by_platform.items()
    }
