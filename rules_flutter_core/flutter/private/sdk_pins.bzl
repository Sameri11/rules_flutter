"""Resolves and locks the per-host files in a Flutter SDK."""

load(":repo.bzl", "flutter_sdk", "flutter_tools_packages")
load(":sdk_android_piece.bzl", "sdk_android_piece")
load(":sdk_tree.bzl", "sdk_tree")

_HOSTS = {
    "macos-arm64": {"release_os": "macos", "release_arch": "arm64", "engine_os": "darwin-arm64", "android_engine_os": "darwin-x64", "dart": "darwin-arm64"},
    "linux-x64": {"release_os": "linux", "release_arch": "x64", "engine_os": "linux-x64", "android_engine_os": "linux-x64", "dart": "linux-x64"},
}

# Each spec is (filename, archive type, strip prefix). Shared artifacts have
# the same URL on both hosts but are still recorded in each host's fact set.
_PIECES = {
    "dart-sdk": ("dart-sdk-{dart}.zip", "zip", ""),
    "flutter_patched_sdk": ("flutter_patched_sdk.zip", "zip", ""),
    "flutter_patched_sdk_product": ("flutter_patched_sdk_product.zip", "zip", ""),
    "sky_engine": ("sky_engine.zip", "zip", ""),
    "flutter_gpu": ("flutter_gpu.zip", "zip", ""),
    "host_artifacts": ("{engine_os}/artifacts.zip", "zip", ""),
    "font_subset": ("{engine_os}/font-subset.zip", "zip", ""),
    "material_fonts": ("fonts/{material}/fonts.zip", "zip", ""),
    "gradle_wrapper": ("gradle-wrapper/{gradle}/gradle-wrapper.tgz", "tar.gz", ""),
    "engine_stamp": ("{engine}/{file}", "file", ""),
    "framework_source": ("https://github.com/flutter/flutter/archive/{commit}.tar.gz", "tar.gz", "flutter-{commit}"),
    "ios_usb_libimobiledevice": ("", "zip", ""),
    "ios_usb_libusbmuxd": ("", "zip", ""),
    "ios_usb_libplist": ("", "zip", ""),
    "ios_usb_openssl": ("", "zip", ""),
    "ios_usb_libimobiledeviceglue": ("", "zip", ""),
    "ios_usb_ios-deploy": ("", "zip", ""),
}

# Flutter 3.50.1's AndroidGenSnapshotArtifacts and
# AndroidInternalBuildArtifacts use these engine archives. Keep them out of
# the assembled SDK tree so builds that do not need Android artifacts stay lazy.
_ANDROID_PIECES = {
    "android_gen_android_arm_profile": ("android-arm-profile/{android_engine_os}.zip", "zip", ""),
    "android_gen_android_arm_release": ("android-arm-release/{android_engine_os}.zip", "zip", ""),
    "android_gen_android_arm64_profile": ("android-arm64-profile/{android_engine_os}.zip", "zip", ""),
    "android_gen_android_arm64_release": ("android-arm64-release/{android_engine_os}.zip", "zip", ""),
    "android_gen_android_x64_profile": ("android-x64-profile/{android_engine_os}.zip", "zip", ""),
    "android_gen_android_x64_release": ("android-x64-release/{android_engine_os}.zip", "zip", ""),
    "android_internal_android_x64": ("android-x64/artifacts.zip", "zip", ""),
    "android_internal_android_arm": ("android-arm/artifacts.zip", "zip", ""),
    "android_internal_android_arm_profile": ("android-arm-profile/artifacts.zip", "zip", ""),
    "android_internal_android_arm_release": ("android-arm-release/artifacts.zip", "zip", ""),
    "android_internal_android_arm64": ("android-arm64/artifacts.zip", "zip", ""),
    "android_internal_android_arm64_profile": ("android-arm64-profile/artifacts.zip", "zip", ""),
    "android_internal_android_arm64_release": ("android-arm64-release/artifacts.zip", "zip", ""),
    "android_internal_android_x64_profile": ("android-x64-profile/artifacts.zip", "zip", ""),
    "android_internal_android_x64_release": ("android-x64-release/artifacts.zip", "zip", ""),
}
_ALL_PINNED_PIECES = dict(_PIECES)
_ALL_PINNED_PIECES.update(_ANDROID_PIECES)

_STORAGE_ROOT = "https://storage.googleapis.com"
_STORAGE = _STORAGE_ROOT + "/flutter_infra_release"
_SCHEMA = 1

def _valid_metadata(value, version):
    if type(value) != "dict" or value.get("schema") != _SCHEMA or value.get("version") != version:
        return False
    for field in ("framework_commit", "dart_sdk_version", "engine_revision", "engine_content_hash", "material_fonts_version", "gradle_wrapper_version"):
        if type(value.get(field)) != "string" or not value[field]:
            return False
    usb_versions = value.get("ios_usb_versions")
    if type(usb_versions) != "dict":
        return False
    for name, usb_version in usb_versions.items():
        if type(name) != "string" or type(usb_version) != "string" or not usb_version:
            return False
    return True

def _valid_pin(value, version):
    if not _valid_metadata(value, version) or "framework_commit_date" in value:
        return False
    hosts = value.get("hosts")
    if type(hosts) != "dict" or sorted(hosts.keys()) != sorted(_HOSTS.keys()):
        return False
    for host in _HOSTS:
        pieces = hosts[host]
        expected_pieces = [name for name in _ALL_PINNED_PIECES if not name.startswith("ios_usb_") or host == "macos-arm64"]
        if type(pieces) != "dict" or sorted(pieces.keys()) != sorted(expected_pieces):
            return False
        for pin in pieces.values():
            sha = pin.get("sha256", "") if type(pin) == "dict" else ""
            if type(pin) != "dict" or type(pin.get("url")) != "string" or len(sha) != 64:
                return False
            for index in range(len(sha)):
                if sha[index] not in "0123456789abcdef":
                    return False
    return True

def _download(ctx, url, output):
    result = ctx.download(url = url, output = output, allow_fail = True)
    if not result.success:
        fail("Could not resolve Flutter SDK metadata from {}: {}".format(url, result))
    return result.sha256

def _read_download(ctx, url, output):
    _download(ctx, url, output)
    return ctx.read(output)

def _release_commit(ctx, version, host):
    url = "{}/releases/releases_{}.json".format(_STORAGE, _HOSTS[host]["release_os"])
    releases = json.decode(_read_download(ctx, url, "flutter_releases_{}.json".format(host)))
    for release in releases.get("releases", []):
        if (
            release.get("version") == version and
            release.get("channel") == "stable" and
            release.get("dart_sdk_arch") == _HOSTS[host]["release_arch"]
        ):
            return release
    fail("Flutter {} is not listed as a stable {} release.".format(version, host))

def _pin_version(ctx, version, overrides, existing):
    if _valid_metadata(existing, version):
        commit = existing["framework_commit"]
        dart_sdk_version = existing["dart_sdk_version"]
        engine_revision = existing["engine_revision"]
        engine_hash = existing["engine_content_hash"]
        material = existing["material_fonts_version"]
        gradle = existing["gradle_wrapper_version"]
        usb_versions = dict(existing["ios_usb_versions"])
    else:
        releases = {host: _release_commit(ctx, version, host) for host in _HOSTS}
        commit = releases["macos-arm64"]["hash"]
        if releases["linux-x64"]["hash"] != commit:
            fail("Flutter {} resolves to different framework commits across supported hosts.".format(version))
        dart_sdk_version = releases["macos-arm64"]["dart_sdk_version"]
        engine_revision = _read_download(
            ctx,
            "https://raw.githubusercontent.com/flutter/flutter/{}/bin/internal/engine.version".format(commit),
            "engine.version",
        ).strip()
        stamp_url = "{}/flutter/{}/engine_stamp.json".format(_STORAGE, engine_revision)
        stamp = json.decode(_read_download(ctx, stamp_url, "engine_stamp.json"))
        engine_hash = stamp.get("content_hash")
        if not engine_hash:
            fail("Flutter engine_stamp.json at {} has no content_hash.".format(stamp_url))

        material = _read_download(
            ctx,
            "https://raw.githubusercontent.com/flutter/flutter/{}/bin/internal/material_fonts.version".format(commit),
            "material_fonts.version",
        ).strip()
        gradle = _read_download(
            ctx,
            "https://raw.githubusercontent.com/flutter/flutter/{}/bin/internal/gradle_wrapper.version".format(commit),
            "gradle_wrapper.version",
        ).strip()
        usb_versions = {}

    for name in ("libimobiledevice", "libusbmuxd", "libplist", "openssl", "libimobiledeviceglue", "ios-deploy"):
        if name not in usb_versions:
            usb_versions[name] = _read_download(
                ctx,
                "https://raw.githubusercontent.com/flutter/flutter/{}/bin/internal/{}.version".format(commit, name),
                "{}.version".format(name),
            ).strip()

    existing_hosts = existing.get("hosts", {}) if type(existing) == "dict" else {}
    hosts = {}
    pending = []
    for host, host_spec in _HOSTS.items():
        pieces = {}
        old_pieces = existing_hosts.get(host, {})
        for name, spec in _ALL_PINNED_PIECES.items():
            if name.startswith("ios_usb_") and host != "macos-arm64":
                continue
            filename, _, _ = spec
            if name == "framework_source":
                url = filename.format(commit = commit)
            elif name == "engine_stamp":
                url = "{}/flutter/{}/engine_stamp.json".format(_STORAGE, engine_hash)
            elif name.startswith("ios_usb_"):
                artifact = name[len("ios_usb_"):]
                url = "{}/flutter_infra_release/ios-usb-dependencies/arm64_x86_64/{}/{}/{}.zip".format(
                    _STORAGE_ROOT,
                    artifact,
                    usb_versions[artifact],
                    artifact,
                )
            elif name == "material_fonts":
                url = "{}/{}".format(_STORAGE_ROOT, material)
            elif name == "gradle_wrapper":
                url = "{}/{}".format(_STORAGE_ROOT, gradle)
            else:
                url = "{}/flutter/{}/{}".format(
                    _STORAGE,
                    engine_hash,
                    filename.format(
                        dart = host_spec["dart"],
                        engine_os = host_spec["engine_os"],
                        android_engine_os = host_spec["android_engine_os"],
                    ),
                )
            base_url = overrides.get("base_url", "").rstrip("/")
            if base_url and url.startswith(_STORAGE_ROOT):
                url = base_url + url[len(_STORAGE_ROOT):]
            override_urls = overrides.get("urls", {}).get(name)
            if override_urls:
                url = override_urls[0]
            sha = overrides.get("sha256", {}).get(name, "")
            old_pin = old_pieces.get(name, {})
            if not sha and type(old_pin) == "dict" and old_pin.get("url") == url:
                sha = old_pin.get("sha256", "")
            if not sha:
                pending.append((
                    host,
                    name,
                    ctx.download(
                        url = url,
                        output = "pin_{}_{}.bin".format(host, name),
                        allow_fail = True,
                        block = False,
                    ),
                ))
            pieces[name] = {"url": url, "sha256": sha}
        hosts[host] = pieces
    for host, name, download in pending:
        result = download.wait()
        if not result.success:
            fail("Could not resolve Flutter SDK metadata for {}: {}".format(name, result))
        hosts[host][name]["sha256"] = result.sha256
    return {
        "schema": _SCHEMA,
        "version": version,
        "framework_commit": commit,
        "dart_sdk_version": dart_sdk_version,
        "engine_revision": engine_revision,
        "engine_content_hash": engine_hash,
        "material_fonts_version": material,
        "gradle_wrapper_version": gradle,
        "ios_usb_versions": usb_versions,
        "hosts": hosts,
    }

def _host_key(module_ctx):
    os_name = module_ctx.os.name.lower()
    os_key = "macos" if os_name.startswith("mac") else "linux" if os_name.startswith("linux") else ""
    arch = module_ctx.os.arch.lower()
    arch_key = "arm64" if arch in ("arm64", "aarch64") else "x64" if arch in ("x86_64", "amd64") else ""
    key = "{}-{}".format(os_key, arch_key)
    if key not in _HOSTS:
        fail("Flutter SDK provisioning does not support host {} {}.".format(module_ctx.os.name, module_ctx.os.arch))
    return key

def _flutter_extension_impl(module_ctx):
    sdk_tags = []
    host_tags = []
    for module in module_ctx.modules:
        if module.is_root:
            sdk_tags = module.tags.sdk
            host_tags = module.tags.host_sdk
    if not sdk_tags and not host_tags:
        flutter_sdk(name = "flutter_sdk", version = "")
        flutter_tools_packages(name = "flutter_tools_packages")
        message = "The root module must declare flutter.sdk(version = \"X.Y.Z\") or flutter.host_sdk(version = \"X.Y.Z\") to build Flutter targets."
        for android_host in _HOSTS:
            for piece in _ANDROID_PIECES:
                sdk_android_piece(
                    name = "flutter_android_{}_{}".format(piece, android_host.replace("-", "_")),
                    urls = [],
                    sha256 = "",
                    failure_message = message,
                )
        return module_ctx.extension_metadata(reproducible = True)
    if sdk_tags and host_tags:
        fail("Declare either flutter.sdk or flutter.host_sdk, not both.")
    if len(sdk_tags) + len(host_tags) != 1:
        fail("The root module must declare exactly one flutter.sdk(version = \"X.Y.Z\") or flutter.host_sdk(version = \"X.Y.Z\") tag.")
    if host_tags:
        flutter_sdk(name = "flutter_sdk", version = host_tags[0].version)
        flutter_tools_packages(name = "flutter_tools_packages")
        return module_ctx.extension_metadata(reproducible = True)

    tag = sdk_tags[0]
    facts = getattr(module_ctx, "facts", {})
    pins = facts.get(tag.version)
    if not _valid_pin(pins, tag.version):
        pins = _pin_version(module_ctx, tag.version, {
            "sha256": tag.sha256,
            "urls": tag.urls,
            "base_url": tag.base_url,
        }, pins if type(pins) == "dict" else {})
    host = _host_key(module_ctx)
    selected = pins["hosts"][host]
    urls = {}
    sha256 = {}
    archive_types = {}
    strip_prefixes = {}
    for piece, pin in selected.items():
        if piece not in _PIECES:
            continue
        _, archive_type, strip_prefix = _PIECES[piece]
        if piece == "framework_source":
            strip_prefix = "flutter-" + pins["framework_commit"]
        piece_urls = tag.urls.get(piece, [pin["url"]])
        base_url = tag.base_url.rstrip("/")
        if base_url and not tag.urls.get(piece) and pin["url"].startswith(_STORAGE_ROOT):
            piece_urls = [base_url + pin["url"][len(_STORAGE_ROOT):]]
        urls[piece] = piece_urls
        sha256[piece] = tag.sha256.get(piece, pin["sha256"])
        archive_types[piece] = archive_type
        strip_prefixes[piece] = strip_prefix
    ios_usb_versions = pins["ios_usb_versions"] if host == "macos-arm64" else {}
    sdk_tree(
        name = "flutter_sdk",
        urls = urls,
        sha256 = sha256,
        archive_types = archive_types,
        strip_prefixes = strip_prefixes,
        ios_usb_names = sorted(ios_usb_versions.keys()),
        engine_host_dir = "darwin-x64" if host.startswith("macos") else "linux-x64",
        engine_revision = pins["engine_revision"],
        engine_content_hash = pins["engine_content_hash"],
        framework_version = pins["version"],
        framework_commit = pins["framework_commit"],
        dart_sdk_version = pins["dart_sdk_version"],
        material_fonts_version = pins["material_fonts_version"],
        gradle_wrapper_version = pins["gradle_wrapper_version"],
        ios_usb_versions = ios_usb_versions,
    )

    for android_host in _HOSTS:
        for piece in _ANDROID_PIECES:
            pin = pins["hosts"][android_host][piece]
            base_url = tag.base_url.rstrip("/")
            piece_urls = tag.urls.get(piece, [pin["url"]])
            if base_url and not tag.urls.get(piece) and pin["url"].startswith(_STORAGE_ROOT):
                piece_urls = [base_url + pin["url"][len(_STORAGE_ROOT):]]
            sdk_android_piece(
                name = "flutter_android_{}_{}".format(piece, android_host.replace("-", "_")),
                urls = piece_urls,
                sha256 = tag.sha256.get(piece, pin["sha256"]),
            )

    return module_ctx.extension_metadata(reproducible = True, facts = {tag.version: pins})

_sdk_tag = tag_class(attrs = {
    "version": attr.string(mandatory = True),
    "sha256": attr.string_dict(),
    "urls": attr.string_list_dict(),
    "base_url": attr.string(),
})
_host_sdk_tag = tag_class(attrs = {"version": attr.string(mandatory = True)})

flutter_sdk_extension = module_extension(
    implementation = _flutter_extension_impl,
    tag_classes = {"sdk": _sdk_tag, "host_sdk": _host_sdk_tag},
)
