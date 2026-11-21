"""Source pins for the test-kernel driver, keyed by Flutter version (frameworkVersion).

Supported: 3.50.1, the version CI uses. A version with no entry builds no driver.

To add a version: take `dart_revision` from the SDK's dart-sdk/revision, `native_commit` from
its DEPS entry for third_party/pkg/native, and the sha256 of each GitHub commit archive and pub
archive. Each pub archive unpacks to pub/<name>-<version>/. Every `packages` entry is
(name, rootUri relative to the repository root, packageUri), and the root must be an unpacked
sdk/, native/ or pub/ directory. The repository rule fails if the SDK's revision differs from
dart_revision. Then add the version's golden entries in tests/test_kernel_driver/golden.bzl.

PARSER_PINS (the metadata parser) use the same scheme with pub archives only. Each entry is
(name, version, sha256, languageVersion), where languageVersion is the lower bound of the
package's pubspec `environment.sdk`: _fe_analyzer_shared does not compile without it. The
closure is test_core's and analyzer's, and every package's constraint must hold at the locked
version. A Flutter version with no entry uses the newest one, with a warning.
"""

# The SDK packages in the closure. Only their lib/ trees and pubspecs are declared as inputs.
_SDK_PKGS = ["_fe_analyzer_shared", "build_integration", "front_end", "kernel", "vm"]

PINS = {
    "3.50.1": {
        "dart_revision": "fa8c1270c374c1346931583a17c3b7f278d3822d",
        "sdk_sha256": "a0aae8ba3088a0a4b0b793d8d860da7fbc602330489385c25f6834925cb759a1",
        "native_commit": "27f767827be80615378e3c0b2d936ac8b4cefaa8",
        "native_sha256": "d971d8340e7ec9e01afb4c5b0a9c6a84cedd4aa0c5edac6b979de28a4d458cbb",
        "pub_archives": [
            ("args", "2.7.0", "d0481093c50b1da8910eb0bb301626d4d8eb7284aa739614d2b394ee09e3ea04"),
            ("collection", "1.19.1", "2f5709ae4d3d59dd8f7cd309b4e023046b57d8a6c82130785d2b0e5868084e76"),
            ("crypto", "3.0.7", "c8ea0233063ba03258fbcf2ca4d6dadfefe14f02fab57702265467a19f27fadf"),
            ("meta", "1.19.0", "307249ce4ff29d58a18e97f6345f539382eb9c9c29ecda628900f31de0443dd9"),
            ("package_config", "3.0.0", "ffcf4cf3d6c0b74ac43708d9f56625506e8a68aa935abe9d267a7330f320eb5d"),
            ("path", "1.9.1", "75cca69d1490965be98c73ceaea117e8a04dd21217b37b292c9ddbec0d955bc5"),
            ("pub_semver", "2.2.1", "261236774e8b1d69cfc6b9eabbc96c40f25e7a2d6b171f3385d4f65d5734fb24"),
            ("source_span", "1.10.2", "56a02f1f4cd1a2d96303c0144c93bd6d909eea6bee6bf5a0e0b685edbd4c47ab"),
            ("string_scanner", "1.4.1", "921cd31725b72fe181906c6a94d987c78e3b98c2e205b397ea399d4054872b43"),
            ("term_glyph", "1.2.2", "7f554798625ea768a7518313e58f83891c7f5024f88e46e7182a4558850a4b8e"),
            ("typed_data", "1.4.0", "f9049c039ebfeb4cf7a7104a675823cd72dba8297f264b6637062516699fa006"),
            ("yaml", "3.1.4", "f67cdd8e07d3c6329146aaef1ba043542b3134c12489f553ca9a7435d1068aea"),
        ],
        "packages": [
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
        ],
        "sdk_pkgs": _SDK_PKGS,
    },
}

# The metadata parser's closure: test_core's parseMetadata and its dependencies, from pub.dev.
PARSER_PINS = {
    "3.50.1": {
        "pub_archives": [
            ("_fe_analyzer_shared", "107.0.0", "fe18c7e37d5acb3b43224fa255281dec007970d6fd01f6d76fcd88ed3777a117", "3.11"),
            ("analyzer", "14.3.0", "f2dde9e50c23fc95b846b4ef334e98c3ae8c0effd5d2453b02fc9fb3f8939791", "3.11"),
            ("args", "2.7.0", "d0481093c50b1da8910eb0bb301626d4d8eb7284aa739614d2b394ee09e3ea04", "3.3"),
            ("async", "2.13.1", "e2eb0491ba5ddb6177742d2da23904574082139b07c1e33b8503b9f46f3e1a37", "3.4"),
            ("boolean_selector", "2.1.2", "8aab1771e1243a5063b8b0ff68042d67334e3feab9e95b9490f9a6ebf73b42ea", "3.1"),
            ("cli_config", "0.2.0", "ac20a183a07002b700f0c25e61b7ee46b23c309d76ab7b7640a028f18e4d99ec", "3.0"),
            ("collection", "1.19.1", "2f5709ae4d3d59dd8f7cd309b4e023046b57d8a6c82130785d2b0e5868084e76", "3.4"),
            ("convert", "3.1.2", "b30acd5944035672bc15c6b7a8b47d773e41e2f17de064350988c5d02adb1c68", "3.4"),
            ("coverage", "1.15.1", "956a3de0725ca232ad353565a8290d3357592bf4250f6f298a185e2d949c5d3d", "3.4"),
            ("crypto", "3.0.7", "c8ea0233063ba03258fbcf2ca4d6dadfefe14f02fab57702265467a19f27fadf", "3.4"),
            ("file", "7.0.1", "a3b4f84adafef897088c160faf7dfffb7696046cb13ae90b508c2cbc95d3b8d4", "3.0"),
            ("frontend_server_client", "4.0.0", "f64a0333a82f30b0cca061bc3d143813a486dc086b574bfb233b7c1372427694", "3.0"),
            ("glob", "2.2.0", "218aeb56050c714f62a3182775320dfa04602b55074873e24e31bbd39bda96fb", "3.3"),
            ("io", "1.1.0", "2635216ca6a737e60de577ffa1a48a0bec76ca8a62917cfc1bb88c14c570646f", "3.4"),
            ("logging", "1.3.0", "c8245ada5f1717ed44271ed1c26b8ce85ca3228fd2ffdb75468ab01979309d61", "3.4"),
            ("meta", "1.19.0", "307249ce4ff29d58a18e97f6345f539382eb9c9c29ecda628900f31de0443dd9", "3.5"),
            ("package_config", "2.2.0", "f096c55ebb7deb7e384101542bfba8c52696c1b56fca2eb62827989ef2353bbc", "3.4"),
            ("path", "1.9.1", "75cca69d1490965be98c73ceaea117e8a04dd21217b37b292c9ddbec0d955bc5", "3.4"),
            ("pool", "1.5.3", "4177f68c237ea2128d1bee66ac17b2ce05ba3dbaafcbdd54c5d40a39d0b6b11c", "3.4"),
            ("pub_semver", "2.2.1", "261236774e8b1d69cfc6b9eabbc96c40f25e7a2d6b171f3385d4f65d5734fb24", "3.4"),
            ("source_map_stack_trace", "2.1.2", "c0713a43e323c3302c2abe2a1cc89aa057a387101ebd280371d6a6c9fa68516b", "3.3"),
            ("source_maps", "0.10.14", "14c2945847669b44089bb1222f66873d7ff7103c58911917f2a63c5a62327898", "3.3"),
            ("source_span", "1.10.2", "56a02f1f4cd1a2d96303c0144c93bd6d909eea6bee6bf5a0e0b685edbd4c47ab", "3.1"),
            ("stack_trace", "1.12.2", "277654b3034d17ac6f9f1cb5595db011b1d5d41e8806866db28e0abaa101c490", "3.4"),
            ("stream_channel", "2.1.4", "969e04c80b8bcdf826f8f16579c7b14d780458bd97f56d107d3950fdbeef059d", "3.3"),
            ("string_scanner", "1.4.1", "921cd31725b72fe181906c6a94d987c78e3b98c2e205b397ea399d4054872b43", "3.1"),
            ("term_glyph", "1.2.2", "7f554798625ea768a7518313e58f83891c7f5024f88e46e7182a4558850a4b8e", "3.1"),
            ("test_api", "0.7.14", "0a10344e901e5b2e63819567951cb6a06673ed6b84f40462188ff5a0c41f371f", "3.11"),
            ("test_core", "0.6.20", "80f3fb49087454e07e7e07c67578cfdd156c8c3a5227d8b3f47c7b2d019c2e93", "3.11"),
            ("typed_data", "1.4.0", "f9049c039ebfeb4cf7a7104a675823cd72dba8297f264b6637062516699fa006", "3.5"),
            ("vm_service", "15.3.0", "5f37239c4851efcef929cea7824e76df7f2f0970aef85d66bbc430afa40e72f0", "3.5"),
            ("watcher", "1.2.1", "1398c9f081a753f9226febe8900fce8f7d0a67163334e1c94a2438339d79d635", "3.4"),
            ("yaml", "3.1.4", "f67cdd8e07d3c6329146aaef1ba043542b3134c12489f553ca9a7435d1068aea", "3.4"),
        ],
    },
}

def version_key(version):
    """Orders dotted versions numerically, so 3.9 sorts before 3.47."""
    return tuple([int(part) for part in version.split(".")])

def select_parser_pin(version, pins):
    """The parser pin for a Flutter version, or the newest pin when it has none.

    Args:
      version: the Flutter version to parse for.
      pins: a dict from Flutter version to pin.

    Returns:
      (pin_version, pin, warning). The warning is None when `version` is pinned.
    """
    if version in pins:
        return version, pins[version], None
    newest = sorted(pins.keys(), key = version_key)[-1]
    return newest, pins[newest], "test_metadata_parser: Flutter {} has no parser pin; parsing with the pin for {}.".format(version, newest)
