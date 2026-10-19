# Pins for the test-kernel driver (flutter/private/test_kernel_driver.bzl).
#
# The driver is compiled from the SDK source at SDK_COMMIT, with the record_use package from
# NATIVE_COMMIT (SDK DEPS), and the other packages from pub, each pinned by sha256. Versions and
# hashes were checked by fetching each archive. Each package below is listed under its
# package_config rootUri, relative to the driver repository root.

SDK_COMMIT = "1d1a730ef918d602aedafc939a4cf5940e7589ab"
NATIVE_COMMIT = "d51c53334486af69435b0b45c4bdfe303a830170"

# Paths in the SDK checkout (sparse) needed by the driver closure.
SDK_SPARSE_PATHS = [
    "pkg/_fe_analyzer_shared",
    "pkg/build_integration",
    "pkg/front_end",
    "pkg/kernel",
    "pkg/vm",
]

# package_config entries, as (name, rootUri relative to the repository root, packageUri).
PACKAGE_ROOTS = [
    ("_fe_analyzer_shared", "sdk/pkg/_fe_analyzer_shared/", "lib/"),
    ("args", "pub/args-2.7.0/", "lib/"),
    ("build_integration", "sdk/pkg/build_integration/", "lib/"),
    ("collection", "pub/collection-1.19.1/", "lib/"),
    ("crypto", "pub/crypto-3.0.7/", "lib/"),
    ("front_end", "sdk/pkg/front_end/", "lib/"),
    ("kernel", "sdk/pkg/kernel/", "lib/"),
    ("meta", "pub/meta-1.19.0/", "lib/"),
    ("package_config", "pub/package_config-3.0.0/", "lib/"),
    ("path", "pub/path-1.9.1/", "lib/"),
    ("pub_semver", "pub/pub_semver-2.2.1/", "lib/"),
    ("record_use", "native/pkgs/record_use/", "lib/"),
    ("source_span", "pub/source_span-1.10.2/", "lib/"),
    ("string_scanner", "pub/string_scanner-1.4.1/", "lib/"),
    ("term_glyph", "pub/term_glyph-1.2.2/", "lib/"),
    ("typed_data", "pub/typed_data-1.4.0/", "lib/"),
    ("vm", "sdk/pkg/vm/", "lib/"),
    ("yaml", "pub/yaml-3.1.4/", "lib/"),
]

# Pub archives: (name, version, sha256, url), for the rootUris under pub/.
PUB_ARCHIVES = [
    ("args", "2.7.0", "d0481093c50b1da8910eb0bb301626d4d8eb7284aa739614d2b394ee09e3ea04", "https://pub.dev/api/archives/args-2.7.0.tar.gz"),
    ("collection", "1.19.1", "2f5709ae4d3d59dd8f7cd309b4e023046b57d8a6c82130785d2b0e5868084e76", "https://pub.dev/api/archives/collection-1.19.1.tar.gz"),
    ("crypto", "3.0.7", "c8ea0233063ba03258fbcf2ca4d6dadfefe14f02fab57702265467a19f27fadf", "https://pub.dev/api/archives/crypto-3.0.7.tar.gz"),
    ("meta", "1.19.0", "307249ce4ff29d58a18e97f6345f539382eb9c9c29ecda628900f31de0443dd9", "https://pub.dev/api/archives/meta-1.19.0.tar.gz"),
    ("package_config", "3.0.0", "ffcf4cf3d6c0b74ac43708d9f56625506e8a68aa935abe9d267a7330f320eb5d", "https://pub.dev/api/archives/package_config-3.0.0.tar.gz"),
    ("path", "1.9.1", "75cca69d1490965be98c73ceaea117e8a04dd21217b37b292c9ddbec0d955bc5", "https://pub.dev/api/archives/path-1.9.1.tar.gz"),
    ("pub_semver", "2.2.1", "261236774e8b1d69cfc6b9eabbc96c40f25e7a2d6b171f3385d4f65d5734fb24", "https://pub.dev/api/archives/pub_semver-2.2.1.tar.gz"),
    ("source_span", "1.10.2", "56a02f1f4cd1a2d96303c0144c93bd6d909eea6bee6bf5a0e0b685edbd4c47ab", "https://pub.dev/api/archives/source_span-1.10.2.tar.gz"),
    ("string_scanner", "1.4.1", "921cd31725b72fe181906c6a94d987c78e3b98c2e205b397ea399d4054872b43", "https://pub.dev/api/archives/string_scanner-1.4.1.tar.gz"),
    ("term_glyph", "1.2.2", "7f554798625ea768a7518313e58f83891c7f5024f88e46e7182a4558850a4b8e", "https://pub.dev/api/archives/term_glyph-1.2.2.tar.gz"),
    ("typed_data", "1.4.0", "f9049c039ebfeb4cf7a7104a675823cd72dba8297f264b6637062516699fa006", "https://pub.dev/api/archives/typed_data-1.4.0.tar.gz"),
    ("yaml", "3.1.4", "f67cdd8e07d3c6329146aaef1ba043542b3134c12489f553ca9a7435d1068aea", "https://pub.dev/api/archives/yaml-3.1.4.tar.gz"),
]
