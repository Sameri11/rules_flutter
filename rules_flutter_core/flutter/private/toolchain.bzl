"""Provider and implementation target for the host Flutter SDK toolchain."""

visibility(["//flutter"])

FlutterToolchainInfo = provider(
    doc = "Flutter SDK files used by compiler, AOT, and asset rules.",
    fields = {
        "tools_snapshot": "flutter_tools snapshot file.",
        "tools_package_config": "flutter_tools Dart package configuration.",
        "tools_packages": "Dart source and resources for flutter_tools packages.",
        "tools_cache_state": "Generated Flutter SDK cache-state files required by flutter_tools.",
        "dartaotruntime": "Dart AOT runtime executable file.",
        "frontend_server": "Frontend server snapshot file.",
        "vm_isolate_snapshot": "Host engine's debug VM isolate snapshot file, shipped as the debug overlay's vm_snapshot_data.",
        "isolate_snapshot": "Host engine's debug isolate snapshot file, shipped as the debug overlay's isolate_snapshot_data.",
        "flutter_tester": "Flutter tester host executable, the test runtime that runs compiled kernel.",
        "icu_data": "ICU data file that flutter_tester loads.",
        "sdk_version": "Flutter SDK identity JSON file.",
        "platform_product": "Product patched SDK files.",
        "sdk_layout": "SDK layout manifest mapping staged destinations to pinned piece paths.",
        "platform_debug": "Debug patched SDK files.",
        "sdk_packages": "Depset of the SDK's Dart package files: every `packages/<name>` package plus sky_engine, as lib/, pubspec.yaml and license files.",
        "dart": "Dart SDK executable file, used to run the test-kernel driver.",
        "vm_platform_strong": "VM platform dill the test-kernel driver is compiled against.",
        "dart_sdk_revision": "Dart SDK revision file; the driver's sdk_hash comes from it.",
    },
)

def _flutter_toolchain_impl(ctx):
    return [platform_common.ToolchainInfo(flutter = FlutterToolchainInfo(
        tools_snapshot = ctx.file._tools_snapshot,
        tools_package_config = ctx.file._tools_package_config,
        tools_packages = ctx.attr._tools_packages[DefaultInfo].files,
        tools_cache_state = ctx.attr._tools_cache_state[DefaultInfo].files,
        dartaotruntime = ctx.executable._dartaotruntime,
        dart = ctx.executable._dart,
        vm_platform_strong = ctx.file._vm_platform_strong,
        dart_sdk_revision = ctx.file._dart_sdk_revision,
        frontend_server = ctx.file._frontend_server,
        vm_isolate_snapshot = ctx.file._vm_isolate_snapshot,
        isolate_snapshot = ctx.file._isolate_snapshot,
        flutter_tester = ctx.executable._flutter_tester,
        icu_data = ctx.file._icu_data,
        sdk_version = ctx.file._sdk_version,
        sdk_layout = ctx.file._sdk_layout,
        platform_product = ctx.files._platform_product,
        platform_debug = ctx.files._platform_debug,
        sdk_packages = depset(ctx.files._sdk_packages),
    ))]

def _toolchain_attrs():
    return {
        "_tools_snapshot": attr.label(default = "//flutter/private:flutter_tools_snapshot", allow_single_file = True),
        "_tools_package_config": attr.label(default = "@flutter_tools//:package_config.json", allow_single_file = True),
        "_tools_packages": attr.label(default = "@flutter_tools//:lib", allow_files = True),
        "_tools_cache_state": attr.label(default = "@flutter_sdk//:flutter_tools_cache_state", allow_files = True),
        "_dart": attr.label(default = "@flutter_sdk//:dart", executable = True, cfg = "exec", allow_single_file = True),
        "_dartaotruntime": attr.label(default = "@flutter_sdk//:dartaotruntime", executable = True, cfg = "exec", allow_single_file = True),
        "_vm_platform_strong": attr.label(default = "@flutter_sdk//:vm_platform_strong.dill", allow_single_file = True),
        "_dart_sdk_revision": attr.label(default = "@flutter_sdk//:dart_sdk_revision", allow_single_file = True),
        "_frontend_server": attr.label(default = "@flutter_sdk//:frontend_server.snapshot", allow_single_file = True),
        "_vm_isolate_snapshot": attr.label(default = "@flutter_sdk//:vm_isolate_snapshot.bin", allow_single_file = True),
        "_isolate_snapshot": attr.label(default = "@flutter_sdk//:isolate_snapshot.bin", allow_single_file = True),
        "_flutter_tester": attr.label(default = "@flutter_sdk//:flutter_tester", executable = True, cfg = "exec", allow_single_file = True),
        "_icu_data": attr.label(default = "@flutter_sdk//:icudtl.dat", allow_single_file = True),
        "_sdk_version": attr.label(default = "@flutter_sdk//:flutter.version.json", allow_single_file = True),
        "_platform_product": attr.label(default = "@flutter_sdk//:platform_product", allow_files = True),
        "_platform_debug": attr.label(default = "@flutter_sdk//:platform_debug", allow_files = True),
        "_sdk_packages": attr.label(default = "@flutter_sdk//:sdk_packages", allow_files = True),
        "_sdk_layout": attr.label(default = "@flutter_sdk//:sdk_layout.json", allow_single_file = True),
    }

flutter_toolchain = rule(
    implementation = _flutter_toolchain_impl,
    attrs = _toolchain_attrs(),
)
