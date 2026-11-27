"""Resolves and locks the per-host files in a Flutter SDK."""

load(":engine_artifact.bzl", "engine_artifact_repo")
load(":repo.bzl", "flutter_sdk", "flutter_sdk_lockfile")
load(":sdk_tree.bzl", "sdk_tree")

_HOSTS = {
    "macos-arm64": {"release_os": "macos", "release_arch": "arm64", "engine_os": "darwin-arm64", "dart": "darwin-arm64"},
    "linux-x64": {"release_os": "linux", "release_arch": "x64", "engine_os": "linux-x64", "dart": "linux-x64"},
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
_ALL_PINNED_PIECES = dict(_PIECES)

_STORAGE_ROOT = "https://storage.googleapis.com"
_STORAGE = _STORAGE_ROOT + "/flutter_infra_release"
_SCHEMA = 2

def _valid_metadata(value, version):
    if type(value) != "dict" or value.get("schema") != _SCHEMA or value.get("version") != version:
        return False
    for field in ("framework_commit", "dart_sdk_version", "engine_revision", "engine_content_hash", "material_fonts_version", "gradle_wrapper_version", "flutter_tools_lock_sha256"):
        if type(value.get(field)) != "string" or not value[field]:
            return False
    lock_sha = value["flutter_tools_lock_sha256"]
    if len(lock_sha) != 64:
        return False
    for index in range(len(lock_sha)):
        if lock_sha[index] not in "0123456789abcdef":
            return False
    usb_versions = value.get("ios_usb_versions")
    if type(usb_versions) != "dict":
        return False
    for name, usb_version in usb_versions.items():
        if type(name) != "string" or type(usb_version) != "string" or not usb_version:
            return False
    for name in ("libimobiledevice", "libusbmuxd", "libplist", "openssl", "libimobiledeviceglue", "ios-deploy"):
        if type(usb_versions.get(name)) != "string" or not usb_versions[name]:
            return False
    return True

def _canonical_piece_url(value, host, name):
    commit = value["framework_commit"]
    engine_hash = value["engine_content_hash"]
    filename = _PIECES[name][0]
    if name == "framework_source":
        return filename.format(commit = commit)
    if name == "engine_stamp":
        return "{}/flutter/{}/engine_stamp.json".format(_STORAGE, engine_hash)
    if name.startswith("ios_usb_"):
        artifact = name[len("ios_usb_"):]
        return "{}/flutter_infra_release/ios-usb-dependencies/arm64_x86_64/{}/{}/{}.zip".format(
            _STORAGE_ROOT,
            artifact,
            value["ios_usb_versions"][artifact],
            artifact,
        )
    if name == "material_fonts":
        return "{}/{}".format(_STORAGE_ROOT, value["material_fonts_version"])
    if name == "gradle_wrapper":
        return "{}/{}".format(_STORAGE_ROOT, value["gradle_wrapper_version"])
    host_spec = _HOSTS[host]
    return "{}/flutter/{}/{}".format(
        _STORAGE,
        engine_hash,
        filename.format(dart = host_spec["dart"], engine_os = host_spec["engine_os"]),
    )

def _valid_pin(value, version):
    if not _valid_metadata(value, version):
        return False
    hosts = value.get("hosts")
    if type(hosts) != "dict" or sorted(hosts.keys()) != sorted(_HOSTS.keys()):
        return False
    for host in _HOSTS:
        pieces = hosts[host]
        expected_pieces = [name for name in _ALL_PINNED_PIECES if not name.startswith("ios_usb_") or host == "macos-arm64"]
        if type(pieces) != "dict" or sorted(pieces.keys()) != sorted(expected_pieces):
            return False
        for name, pin in pieces.items():
            sha = pin.get("sha256", "") if type(pin) == "dict" else ""
            if type(pin) != "dict" or pin.get("url") != _canonical_piece_url(value, host, name) or len(sha) != 64:
                return False
            for index in range(len(sha)):
                if sha[index] not in "0123456789abcdef":
                    return False
    return True

def _mirror_url(url, base_url):
    base_url = base_url.rstrip("/")
    if base_url and url.startswith(_STORAGE_ROOT):
        return base_url + url[len(_STORAGE_ROOT):]
    return url

def _download(ctx, url, output, base_url = ""):
    fetch_url = _mirror_url(url, base_url)
    result = ctx.download(url = fetch_url, output = output, allow_fail = True)
    if not result.success:
        fail("Could not resolve Flutter SDK metadata from {}: {}".format(fetch_url, result))
    return result.sha256

def _read_download(ctx, url, output, base_url = ""):
    _download(ctx, url, output, base_url)
    return ctx.read(output)

def _release_commit(ctx, version, host, base_url):
    url = "{}/releases/releases_{}.json".format(_STORAGE, _HOSTS[host]["release_os"])
    releases = json.decode(_read_download(ctx, url, "flutter_releases_{}.json".format(host), base_url))
    for release in releases.get("releases", []):
        if (
            release.get("version") == version and
            release.get("channel") == "stable" and
            release.get("dart_sdk_arch") == _HOSTS[host]["release_arch"]
        ):
            return release
    fail("Flutter {} is not listed as a stable {} release.".format(version, host))

def _pin_version(ctx, version, base_url, existing):
    if _valid_metadata(existing, version):
        commit = existing["framework_commit"]
        dart_sdk_version = existing["dart_sdk_version"]
        engine_revision = existing["engine_revision"]
        engine_hash = existing["engine_content_hash"]
        material = existing["material_fonts_version"]
        gradle = existing["gradle_wrapper_version"]
        flutter_tools_lock_sha = existing["flutter_tools_lock_sha256"]
        usb_versions = dict(existing["ios_usb_versions"])
    else:
        releases = {host: _release_commit(ctx, version, host, base_url) for host in _HOSTS}
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
        stamp = json.decode(_read_download(ctx, stamp_url, "engine_stamp.json", base_url))
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
        flutter_tools_lock_sha = _download(
            ctx,
            "https://raw.githubusercontent.com/flutter/flutter/{}/pubspec.lock".format(commit),
            "flutter_tools.pubspec.lock",
        )
        usb_versions = {}
    for name in ("libimobiledevice", "libusbmuxd", "libplist", "openssl", "libimobiledeviceglue", "ios-deploy"):
        if name not in usb_versions:
            usb_versions[name] = _read_download(
                ctx,
                "https://raw.githubusercontent.com/flutter/flutter/{}/bin/internal/{}.version".format(commit, name),
                "{}.version".format(name),
            ).strip()

    existing_hosts = existing.get("hosts", {}) if _valid_metadata(existing, version) else {}
    hosts = {}
    pending_by_url = {}
    pending_uses = {}
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
                    ),
                )
            old_pin = old_pieces.get(name, {})
            sha = old_pin.get("sha256", "") if type(old_pin) == "dict" and old_pin.get("url") == url else ""
            pieces[name] = {"url": url, "sha256": sha}
            if not sha:
                fetch_url = _mirror_url(url, base_url)
                if fetch_url not in pending_by_url:
                    pending_by_url[fetch_url] = ctx.download(
                        url = fetch_url,
                        output = "pin_{}.bin".format(len(pending_by_url)),
                        allow_fail = True,
                        block = False,
                    )
                    pending_uses[fetch_url] = []
                pending_uses[fetch_url].append((host, name))
        hosts[host] = pieces
    for url, download in pending_by_url.items():
        result = download.wait()
        if not result.success:
            fail("Could not resolve Flutter SDK metadata for {}: {}".format(url, result))
        for host, name in pending_uses[url]:
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
        "flutter_tools_lock_sha256": flutter_tools_lock_sha,
        "ios_usb_versions": usb_versions,
        "hosts": hosts,
    }

def _engine_artifact_tags(module_ctx):
    tags = {}
    for module in module_ctx.modules:
        for tag in module.tags.engine_artifact:
            if (
                not tag.name or
                not tag.path or
                tag.path.startswith("/") or
                ".." in tag.path.split("/")
            ):
                fail("flutter.engine_artifact requires a name and a relative path without `..` segments.")
            previous = tags.get(tag.name)
            if previous and previous.path != tag.path:
                fail("Conflicting flutter.engine_artifact declarations for name `{}`: `{}` and `{}`.".format(tag.name, previous.path, tag.path))
            tags[tag.name] = tag
    return tags

def _pin_engine_artifacts(ctx, tags, engine_hash, base_url, existing):
    old = existing.get("engine_artifacts", {}) if type(existing) == "dict" else {}
    pins = {}
    pending = {}
    uses = {}
    for name, tag in tags.items():
        url = "{}/flutter/{}/{}".format(_STORAGE, engine_hash, tag.path)
        old_pin = old.get(name, {})
        sha = old_pin.get("sha256", "") if type(old_pin) == "dict" and old_pin.get("url") == url and old_pin.get("path") == tag.path else ""
        pins[name] = {"path": tag.path, "url": url, "sha256": sha}
        if not sha:
            fetch_url = _mirror_url(url, base_url)
            if fetch_url not in pending:
                pending[fetch_url] = ctx.download(
                    url = fetch_url,
                    output = "pin_engine_artifact_{}.bin".format(len(pending)),
                    allow_fail = True,
                    block = False,
                )
                uses[fetch_url] = []
            uses[fetch_url].append(name)
    for url, download in pending.items():
        result = download.wait()
        if not result.success:
            fail("Could not resolve Flutter engine artifact from {}: {}".format(url, result))
        for name in uses[url]:
            pins[name]["sha256"] = result.sha256
    return pins

def _create_engine_artifact_repos(tags, pins, sdk_tag, failure_message):
    for name in tags:
        pin = pins.get(name)
        if failure_message:
            engine_artifact_repo(
                name = name,
                urls = [],
                sha256 = "",
                failure_message = failure_message,
            )
        else:
            urls = sdk_tag.urls.get(name, [pin["url"]])
            if sdk_tag.base_url and not sdk_tag.urls.get(name) and pin["url"].startswith(_STORAGE_ROOT):
                urls = [_mirror_url(pin["url"], sdk_tag.base_url)]
            engine_artifact_repo(
                name = name,
                urls = urls,
                sha256 = sdk_tag.sha256.get(name, pin["sha256"]),
            )

def _host_key(module_ctx):
    os_name = module_ctx.os.name.lower()
    os_key = "macos" if os_name.startswith("mac") else "linux" if os_name.startswith("linux") else ""
    arch = module_ctx.os.arch.lower()
    arch_key = "arm64" if arch in ("arm64", "aarch64") else "x64" if arch in ("x86_64", "amd64") else ""
    key = "{}-{}".format(os_key, arch_key)
    return key if key in _HOSTS else None

def _unsupported_sdk_download_version(version):
    version_without_build = version.split("+")[0]
    is_prerelease = "-" in version_without_build
    parts = version_without_build.split("-")[0].split(".")
    if len(parts) != 3 or not all([part.isdigit() for part in parts]):
        return False
    major, minor = [int(part) for part in parts[:2]]
    return (
        is_prerelease or
        major < 3 or
        (major == 3 and minor < 47)
    )

def _flutter_extension_impl(module_ctx):
    sdk_tags = []
    for module in module_ctx.modules:
        if module.is_root:
            sdk_tags = module.tags.sdk
    artifact_tags = _engine_artifact_tags(module_ctx)
    if len(sdk_tags) > 1:
        fail("The root module must declare exactly one flutter.sdk(version = \"X.Y.Z\") tag.")
    if not sdk_tags:
        message = "The root module must declare flutter.sdk(version = \"X.Y.Z\") to build Flutter targets."
        flutter_sdk(name = "flutter_sdk", failure_message = message)
        flutter_sdk_lockfile(name = "flutter_tools_lockfile")
        _create_engine_artifact_repos(artifact_tags, {}, None, message)
        return module_ctx.extension_metadata(reproducible = True)

    tag = sdk_tags[0]
    if _unsupported_sdk_download_version(tag.version):
        fail("Flutter SDK version {} is unsupported; pin version 3.47.0 or newer.".format(tag.version))

    host = _host_key(module_ctx)
    facts = getattr(module_ctx, "facts", {})
    existing = facts.get(tag.version)
    pins = existing
    if not _valid_pin(pins, tag.version):
        pins = _pin_version(module_ctx, tag.version, tag.base_url, pins if type(pins) == "dict" else {})
    engine_artifacts = {} if host == None else _pin_engine_artifacts(
        module_ctx,
        artifact_tags,
        pins["engine_content_hash"],
        tag.base_url,
        pins,
    )
    pins = dict(pins)
    pins["engine_artifacts"] = engine_artifacts

    if host == None:
        message = "Flutter SDK provisioning does not support host {} {}.".format(module_ctx.os.name, module_ctx.os.arch)
        flutter_sdk(name = "flutter_sdk", failure_message = message)
        flutter_sdk_lockfile(name = "flutter_tools_lockfile")
        _create_engine_artifact_repos(artifact_tags, {}, tag, message)
        return module_ctx.extension_metadata(reproducible = True, facts = {tag.version: pins})

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
        if tag.base_url and not tag.urls.get(piece) and pin["url"].startswith(_STORAGE_ROOT):
            piece_urls = [_mirror_url(pin["url"], tag.base_url)]
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
    flutter_sdk_lockfile(
        name = "flutter_tools_lockfile",
        url = "https://raw.githubusercontent.com/flutter/flutter/{}/pubspec.lock".format(pins["framework_commit"]),
        sha256 = pins["flutter_tools_lock_sha256"],
    )
    _create_engine_artifact_repos(artifact_tags, engine_artifacts, tag, "")

    return module_ctx.extension_metadata(reproducible = True, facts = {tag.version: pins})

_sdk_tag = tag_class(
    doc = "Provisions a stable Flutter SDK at version 3.47.0 or newer. `sha256` and `urls` override per-piece pins; `base_url` mirrors Flutter storage URLs. Valid keys are SDK piece names and declared engine artifact names.",
    attrs = {
        "version": attr.string(mandatory = True),
        "sha256": attr.string_dict(doc = "Optional SHA-256 overrides keyed by SDK piece or engine artifact name."),
        "urls": attr.string_list_dict(doc = "Optional download URL lists keyed by SDK piece or engine artifact name."),
        "base_url": attr.string(doc = "Optional mirror for Flutter storage URLs, including release metadata and engine_stamp.json."),
    },
)

_engine_artifact_tag = tag_class(
    doc = "Declares an engine archive repository for a platform ruleset. The path is relative to the engine storage directory for the pinned engine hash.",
    attrs = {
        "name": attr.string(mandatory = True, doc = "Repository name imported by the declaring ruleset."),
        "path": attr.string(mandatory = True, doc = "Archive path relative to the pinned engine hash's storage directory."),
    },
)

flutter_sdk_extension = module_extension(
    implementation = _flutter_extension_impl,
    tag_classes = {"sdk": _sdk_tag, "engine_artifact": _engine_artifact_tag},
)
