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
    "3.47.3": {
        # macOS arm64 archive.
        "29c2c85a130f154a5097ea9ab3a3fc9031fb4b4ac8126a9c05c9c6a19048e911": "7820b4c1ecf6a8d75958e3e5975ccf15646d9e2f4ca129bcb874502acb2b3554",
        # Linux x64 archive.
        "883d97292177020d42bed41ffcc3755319bb499872239715dde5e0ae3a723f67": "d817d9017f09ca789a5a28084779da8bab56746d1640ddb5f52a02871dc8d1ee",
    },
}

def golden_entries():
    """Flattens GOLDEN to "version platform_sha256" keys, the form the golden test reads."""
    return {
        version + " " + platform: driver
        for version, by_platform in GOLDEN.items()
        for platform, driver in by_platform.items()
    }
