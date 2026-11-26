"""Resolves and locks the per-host files in a Flutter SDK."""

load(":repo.bzl", "flutter_sdk", "flutter_tools_packages")
load(":sdk_tree.bzl", "sdk_tree")
load(":sdk_artifact.bzl", "sdk_artifact")

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
    "font_subset": ("{engine_os}/font-subset.zip", "zip", ""),
    "material_fonts": ("fonts/{material}/fonts.zip", "zip", ""),
    "gradle_wrapper": ("gradle-wrapper/{gradle}/gradle-wrapper.tgz", "tar.gz", ""),
    "engine_stamp": ("{engine}/{file}", "file", ""),
    "framework_source": ("https://github.com/flutter/flutter/archive/{commit}.tar.gz", "tar.gz", "flutter-{commit}"),
}

_STORAGE_ROOT = "https://storage.googleapis.com"
_STORAGE = _STORAGE_ROOT + "/flutter_infra_release"
_SCHEMA = 1


def _valid_pin(value, version):
    if type(value) != "dict" or value.get("schema") != _SCHEMA or value.get("version") != version:
        return False
    for field in ("framework_commit", "framework_commit_date", "dart_sdk_version", "engine_revision", "engine_content_hash", "material_fonts_version", "gradle_wrapper_version"):
        if type(value.get(field)) != "string" or not value[field]:
            return False
    hosts = value.get("hosts")
    if type(hosts) != "dict" or sorted(hosts.keys()) != sorted(_HOSTS.keys()):
        return False
    for host in _HOSTS:
        pieces = hosts[host]
        if type(pieces) != "dict" or sorted(pieces.keys()) != sorted(_PIECES.keys()):
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


def _pin_version(ctx, version, overrides):
    releases = {host: _release_commit(ctx, version, host) for host in _HOSTS}
    commit = releases["macos-arm64"]["hash"]
    if releases["linux-x64"]["hash"] != commit:
        fail("Flutter {} resolves to different framework commits across supported hosts.".format(version))
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

    framework_info = json.decode(_read_download(
        ctx,
        "https://api.github.com/repos/flutter/flutter/commits/{}".format(commit),
        "framework_commit.json",
    ))
    framework_date = framework_info["commit"]["author"]["date"]

    hosts = {}
    for host, host_spec in _HOSTS.items():
        pieces = {}
        for name, spec in _PIECES.items():
            filename, _, _ = spec
            if name == "framework_source":
                url = filename.format(commit=commit)
            elif name == "engine_stamp":
                url = "{}/flutter/{}/engine_stamp.json".format(_STORAGE, engine_hash)
            elif name == "material_fonts":
                url = "{}/{}".format(_STORAGE_ROOT, material)
            elif name == "gradle_wrapper":
                url = "{}/{}".format(_STORAGE_ROOT, gradle)
            else:
                url = "{}/flutter/{}/{}".format(
                    _STORAGE,
                    engine_hash,
                    filename.format(dart = host_spec["dart"], engine_os = host_spec["engine_os"]),
                )
            base_url = overrides.get("base_url", "").rstrip("/")
            if base_url and url.startswith(_STORAGE_ROOT):
                url = base_url + url[len(_STORAGE_ROOT):]
            override_urls = overrides.get("urls", {}).get(name)
            if override_urls:
                url = override_urls[0]
            sha = overrides.get("sha256", {}).get(name, "")
            if not sha:
                sha = _download(ctx, url, "pin_{}_{}.bin".format(host, name))
            pieces[name] = {"url": url, "sha256": sha}
        hosts[host] = pieces
    return {
        "schema": _SCHEMA,
        "version": version,
        "framework_commit": commit,
        "framework_commit_date": framework_date,
        "dart_sdk_version": releases["macos-arm64"]["dart_sdk_version"],
        "engine_revision": engine_revision,
        "engine_content_hash": engine_hash,
        "material_fonts_version": material,
        "gradle_wrapper_version": gradle,
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


def _piece_label(host, piece):
    repo = "flutter_sdk_{}_{}".format(host, piece.replace("-", "_"))
    return "@{}//:BUILD.bazel".format(repo)


def _flutter_extension_impl(module_ctx):
    sdk_tags = []
    host_tags = []
    for module in module_ctx.modules:
        if module.is_root:
            sdk_tags = module.tags.sdk
            host_tags = module.tags.host_sdk
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
        })
    for host, pieces in pins["hosts"].items():
        for piece, pin in pieces.items():
            _, archive_type, strip_prefix = _PIECES[piece]
            if piece == "framework_source":
                strip_prefix = "flutter-" + pins["framework_commit"]
            urls = tag.urls.get(piece, [pin["url"]])
            base_url = tag.base_url.rstrip("/")
            if base_url and not tag.urls.get(piece) and pin["url"].startswith(_STORAGE_ROOT):
                urls = [base_url + pin["url"][len(_STORAGE_ROOT):]]
            sdk_artifact(
                name = "flutter_sdk_{}_{}".format(host, piece.replace("-", "_")),
                urls = urls,
                sha256 = tag.sha256.get(piece, pin["sha256"]),
                archive_type = archive_type,
                strip_prefix = strip_prefix,
                file_name = "engine_stamp.json" if piece == "engine_stamp" else "artifact.json",
            )
    host = _host_key(module_ctx)
    repos = {piece: _piece_label(host, piece) for piece in _PIECES}
    sdk_tree(
        name = "flutter_sdk",
        framework_source = repos["framework_source"],
        dart_sdk = repos["dart-sdk"],
        patched_sdk = repos["flutter_patched_sdk"],
        patched_sdk_product = repos["flutter_patched_sdk_product"],
        sky_engine = repos["sky_engine"],
        flutter_gpu = repos["flutter_gpu"],
        host_artifacts = repos["host_artifacts"],
        font_subset = repos["font_subset"],
        material_fonts = repos["material_fonts"],
        gradle_wrapper = repos["gradle_wrapper"],
        engine_stamp = "@flutter_sdk_{}_engine_stamp//:engine_stamp.json".format(host),
        engine_host_dir = "darwin-x64" if host.startswith("macos") else "linux-x64",
        engine_revision = pins["engine_revision"],
        engine_content_hash = pins["engine_content_hash"],
        framework_version = pins["version"],
        framework_commit = pins["framework_commit"],
        framework_commit_date = pins["framework_commit_date"],
        dart_sdk_version = pins["dart_sdk_version"],
        material_fonts_version = pins["material_fonts_version"],
        gradle_wrapper_version = pins["gradle_wrapper_version"],
    )
    flutter_tools_packages(name = "flutter_tools_packages")
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

