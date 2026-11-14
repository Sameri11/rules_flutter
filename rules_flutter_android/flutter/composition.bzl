"""Public building blocks for hand-wired Flutter Android targets."""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("//flutter/private:android.bzl", _flutter_android_manifest = "flutter_android_manifest", _flutter_assets_dir = "flutter_assets_dir")
load("//flutter/private:android_inputs_rules.bzl", _flutter_android_inputs = "flutter_android_inputs", _select_workspace_plugins = "select_workspace_plugins", _workspace_plugin_targets = "workspace_plugin_targets")
load("//flutter/private:apk_check.bzl", _flutter_apk_check = "flutter_apk_check")
load("//flutter/private:embedding.bzl", _FLUTTER_EMBEDDING_ARTIFACTS = "FLUTTER_EMBEDDING_ARTIFACTS", _flutter_embedding_deps = "flutter_embedding_deps")
load("//flutter/private:maven_identity.bzl", _FlutterMavenRepositoryInfo = "FlutterMavenRepositoryInfo", _flutter_maven_repository = "flutter_maven_repository")
load("//flutter/private:native_files.bzl", _FlutterNativeFilesByAbiInfo = "FlutterNativeFilesByAbiInfo", _flutter_native_files = "flutter_native_files", _flutter_native_files_by_abi = "flutter_native_files_by_abi")
load("//flutter/private:native_strip.bzl", _android_native_files = "android_native_files")
load("//flutter/private:registrant.bzl", "render_android_registrant")

FlutterNativeFilesByAbiInfo = _FlutterNativeFilesByAbiInfo
FlutterMavenRepositoryInfo = _FlutterMavenRepositoryInfo
android_native_files = _android_native_files
flutter_native_files = _flutter_native_files
flutter_native_files_by_abi = _flutter_native_files_by_abi
flutter_maven_repository = _flutter_maven_repository
flutter_android_inputs = _flutter_android_inputs
flutter_android_manifest = _flutter_android_manifest
flutter_assets_dir = _flutter_assets_dir
flutter_apk_check = _flutter_apk_check
flutter_embedding_deps = _flutter_embedding_deps
FLUTTER_EMBEDDING_ARTIFACTS = _FLUTTER_EMBEDDING_ARTIFACTS
select_workspace_plugins = _select_workspace_plugins
workspace_plugin_targets = _workspace_plugin_targets

_MODE = Label("@rules_flutter_core//flutter:mode")

def _registrant_impl(ctx):
    mode = ctx.attr._mode[BuildSettingInfo].value
    entries = sorted(ctx.attr.plugins + (ctx.attr.dev_plugins if mode == "debug" else []), key = lambda entry: entry.split("|", 1)[0])
    parsed = []
    for entry in entries:
        parts = entry.split("|", 1)
        if len(parts) != 2:
            fail("{}: plugin entries must be name|qualified.class, got {}".format(ctx.label, entry))
        parsed.append((parts[0], parts[1]))
    output = ctx.actions.declare_file(ctx.label.name + "/GeneratedPluginRegistrant.java")
    ctx.actions.write(output, render_android_registrant(parsed))
    return [DefaultInfo(files = depset([output]))]

flutter_plugin_registrant = rule(
    implementation = _registrant_impl,
    doc = "Generates GeneratedPluginRegistrant.java from plugin entries; dev_plugins are included only in debug mode.",
    attrs = {
        "plugins": attr.string_list(doc = "Plugin entries in name|fully.qualified.Class format."),
        "dev_plugins": attr.string_list(doc = "Development plugin entries in name|fully.qualified.Class format; included only in debug mode."),
        "_mode": attr.label(default = _MODE, providers = [BuildSettingInfo]),
    },
)

def _build_config_impl(ctx):
    mode = ctx.attr._mode[BuildSettingInfo].value
    debug = mode == "debug"
    source = (
        "package {};\n\n".format(ctx.attr.package_name) +
        "public final class BuildConfig {\n" +
        "    public static final boolean DEBUG = {};\n".format("true" if debug else "false") +
        "    public static final String BUILD_TYPE = {};\n".format(json.encode("debug" if debug else "release")) +
        "    public static final String LIBRARY_PACKAGE_NAME = {};\n".format(json.encode(ctx.attr.package_name)) +
        "".join(ctx.attr.fields) +
        "    private BuildConfig() {}\n" +
        "}\n"
    )
    output = ctx.actions.declare_file(ctx.label.name + "/BuildConfig.java")
    ctx.actions.write(output, source)
    return [DefaultInfo(files = depset([output]))]

flutter_build_config = rule(
    implementation = _build_config_impl,
    doc = "Generates BuildConfig.java using the package name, selected mode, and extra field declaration lines.",
    attrs = {
        "package_name": attr.string(mandatory = True, doc = "Java package name for the generated BuildConfig class."),
        "fields": attr.string_list(doc = "Raw Java field declaration lines; each entry is emitted verbatim followed by a newline."),
        "_mode": attr.label(default = _MODE, providers = [BuildSettingInfo]),
    },
)
