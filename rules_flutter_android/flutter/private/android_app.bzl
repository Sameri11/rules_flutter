"""A stock android_binary over a flutter_core artifact's Android inputs, with Flutter's defaults.

`flutter_android_app` declares the binary and the glue a standard-layout Flutter app
needs: the version stamp, the resources, the debug manifest, the native libraries
and debug kernel and snapshot files stored uncompressed, and the APK check. Each default is an
argument. Variants of one app share an inputs target through `inputs`, so the
engine strip, the AOT library and the asset copy are built once.
"""

load("@rules_android//rules:rules.bzl", "android_binary", "android_library")
load("@rules_flutter_core//flutter:defs.bzl", "flutter_debug_core")
load(":abis.bzl", "MIN_SDK")
load(":android.bzl", "flutter_android_assets", "flutter_android_manifest", "flutter_assets_dir")
load(":android_inputs_rules.bzl", "flutter_android_inputs")
load(":apk_check.bzl", "flutter_apk_check")
load(":integration_test_runner.bzl", "flutter_android_integration_test")
load(":maven_identity.bzl", "check_flutter_maven_repository")

# Mirrors android.bzl's _MANIFEST_VALUES, which goes with the wrapper.
_MANIFEST_VALUES = {
    "applicationName": "io.flutter.app.FlutterApplication",
    "minSdkVersion": str(MIN_SDK),
    "targetSdkVersion": "36",
}

_MODE_DEBUG = Label("@rules_flutter_core//flutter:mode_debug")
_MODE_RELEASE = Label("@rules_flutter_core//flutter:mode_release")

_INCOMPATIBLE = Label("@platforms//:incompatible")

# The debug files a Dart edit changes. Stored rather than deflated, so a
# rebuild copies ~65 MB instead of recompressing it inside resource packaging.
FLUTTER_DEBUG_UNCOMPRESSED_ASSETS = ["kernel_blob.bin", "isolate_snapshot_data", "vm_snapshot_data"]

def _default_nocompress():
    return [".so"] + select({
        _MODE_DEBUG: FLUTTER_DEBUG_UNCOMPRESSED_ASSETS,
        _MODE_RELEASE: [],
    })

# Sentinels no caller can pass by accident. A string compare would also match a
# consumer who writes the default path explicitly and expects it to be required.
_UNSET = struct(sentinel = "plugins")
_DEFAULT_DEBUG_MANIFEST = struct(sentinel = "debug_manifest")

_TEST_APK_TAG = "flutter-test-apk"

def flutter_android_app(
        name,
        core = None,
        inputs = None,
        plugins = _UNSET,
        maven_repo = None,
        manifest = "src/main/AndroidManifest.xml",
        manifest_values = {},
        resource_files = None,
        debug_manifest = _DEFAULT_DEBUG_MANIFEST,
        apk_check = True,
        deps = [],
        test_apps = {},
        integration_tests = [],
        integration_test_defaults = {},
        **kwargs):
    """A stock android_binary `name` with Flutter's defaults for a standard layout.

    Declares `<name>_inputs` from `core` and `plugins` unless `inputs` names an
    existing flutter_android_inputs target. `test_apps` declares debug APKs with
    the app's identity and Android inputs; test-only Dart artifacts can replace
    their kernel without creating another inputs target. Generated helper targets
    carry the caller's tags plus `manual`.

    Args:
      name: the APK's target name.
      core: the flutter_core target the app runs. Required without `inputs`.
      inputs: a flutter_android_inputs target to reuse, for variants of one app.
        It must be declared by flutter_android_inputs: the macro derives
        `<inputs>_bundle`, `<inputs>_native` and `<inputs>_pubspec` from its name.
        Its `core` and `plugins` are the ones it was declared with, and it must be
        visible from this package.
      plugins: the plugin repository, e.g. "@flutter_plugins", or None for an app
        without plugins.
      maven_repo: optional Maven repository alias. With plugins it must resolve
        to the same canonical repository selected by the project; without plugins
        it defaults to `@flutter_maven` and may be overridden. With `inputs=`, an
        explicit value must match that inputs target's Maven repository.
      manifest: the app's AndroidManifest.xml. Stamped with the core's version.
      manifest_values: values the manifest does not carry. `applicationId` is
        required. `applicationName`, `minSdkVersion` and `targetSdkVersion` default
        to Flutter's values. `versionCode` and `versionName` are refused: the
        version comes from pubspec.yaml.
      resource_files: the app's resources. Defaults to a nonempty `src/main/res/**`;
        `[]` opts out.
      debug_manifest: a manifest merged in debug mode only. Defaults to
        `src/debug/AndroidManifest.xml`, skipped when absent. An explicit path must
        exist. None opts out.
      apk_check: whether to declare `<name>_check_test`, the APK's native-library
        check.
      deps: the app's own targets. The inputs target is appended.
      test_apps: a dictionary from APK suffix to either macro-core settings
        (`entrypoint`, `srcs`, `dart_defines`, optional `app`) or a prebuilt
        `flutter_debug_core` label under `core`. Each entry also accepts Android
        binary attributes; `deps` append to the app's dependencies. Generated APKs
        and check targets are debug-only, `testonly` by default, and `manual`.
      integration_tests: integration-test labels (or a label-to-attribute dict).
        Each declares `<name>_<test>` as a debug APK and `<name>_<test>_test`
        as its adb runner. `shard_count` is refused.
      integration_test_defaults: loading-time attributes shared by the generated
        integration runner tests, overridden by each entry's attributes.
      **kwargs: forwarded to android_binary, and tags and visibility also to
        `<name>_check_test`. `assets` and `assets_dir` are set by the macro and
        refused here.
    """

    maven_validation = []

    # The caller's tags reach every target the macro declares, not only `<name>`.
    internal_tags = list(kwargs.get("tags", []))
    if "manual" not in internal_tags:
        internal_tags.append("manual")
    if inputs != None:
        if core != None:
            fail("flutter_android_app {}: `inputs` is set, so `core` belongs to that inputs target. Pass core = None.".format(name))
        if plugins != _UNSET:
            fail("flutter_android_app {}: `inputs` is set, so `plugins` belongs to that inputs target. Omit plugins.".format(name))
        if maven_repo != None:
            inputs_label = native.package_relative_label(inputs)
            check_flutter_maven_repository(
                name = name + "_maven_repo_check",
                project = inputs_label.same_package_label(inputs_label.name + "_maven_repository"),
                maven_repo = maven_repo + "//:pin",
                tags = internal_tags,
            )
            maven_validation = [":" + name + "_maven_repo_check"]
    else:
        if core == None:
            fail("flutter_android_app {}: pass `core`, the flutter_core target, or `inputs`.".format(name))
        if plugins == _UNSET:
            fail("flutter_android_app {}: pass `plugins`: a plugin repository such as \"@flutter_plugins\", or None for an app without plugins.".format(name))
        inputs = ":" + name + "_inputs"
        flutter_android_inputs(
            name = name + "_inputs",
            core = core,
            plugins = plugins,
            tags = internal_tags,
            maven_repo = maven_repo,
        )

    for owned in ["assets", "assets_dir"]:
        if owned in kwargs:
            fail("flutter_android_app {}: `{}` is set by the macro, which declares the asset bundle of `{}`. Remove it.".format(name, owned, inputs))

    for key in ("versionCode", "versionName"):
        if key in manifest_values:
            fail("flutter_android_app {}: manifest_values['{}'] and the pubspec both set the version. Drop it; the version comes from pubspec.yaml.".format(name, key))

    values = dict(_MANIFEST_VALUES)
    values.update(manifest_values)
    if "applicationId" not in values:
        fail("flutter_android_app {}: manifest_values must set `applicationId`. It is the package name the manifest's relative class names resolve against, and nothing here can infer it.".format(name))

    inputs_label = native.package_relative_label(inputs)
    bundle = inputs_label.same_package_label(inputs_label.name + "_bundle")
    native_label = inputs_label.same_package_label(inputs_label.name + "_native")
    pubspec = inputs_label.same_package_label(inputs_label.name + "_pubspec")

    flutter_android_manifest(
        name = name + "_manifest",
        manifest = manifest,
        pubspec = pubspec,
        tags = internal_tags,
    )

    if resource_files == None:
        resource_files = native.glob(["src/main/res/**"], allow_empty = False)

    debug_manifest_deps = []
    if debug_manifest == _DEFAULT_DEBUG_MANIFEST:
        # The default is optional: a project without a debug manifest still builds.
        debug_manifest = "src/debug/AndroidManifest.xml"
        debug_manifest_files = native.glob([debug_manifest], allow_empty = True)
    elif debug_manifest == None:
        debug_manifest_files = []
    else:
        debug_manifest_files = native.glob([debug_manifest], allow_empty = True)
        if not debug_manifest_files:
            fail("flutter_android_app {}: debug_manifest {} does not exist. Pass None to opt out.".format(name, debug_manifest))
    if debug_manifest_files:
        android_library(
            name = name + "_debug_manifest",
            manifest = debug_manifest,
            exports_manifest = True,
            # Manifest merging needs a package.
            custom_package = values["applicationId"],
            resource_files = [],
            tags = internal_tags,
        )
        debug_manifest_deps = select({
            _MODE_DEBUG: [":" + name + "_debug_manifest"],
            _MODE_RELEASE: [],
        })

    kwargs.setdefault("nocompress_extensions", _default_nocompress())
    android_binary(
        name = name,
        assets = [bundle],
        assets_dir = flutter_assets_dir(assets = bundle),
        manifest = ":" + name + "_manifest",
        manifest_values = values,
        resource_files = resource_files,
        deps = deps + [inputs_label] + debug_manifest_deps + maven_validation,
        **kwargs
    )

    if apk_check:
        flutter_apk_check(
            name = name + "_check_test",
            binary = ":" + name,
            native = [native_label],
            tags = kwargs.get("tags", []),
            visibility = kwargs.get("visibility"),
        )
    _declare_test_apps(
        name = name,
        test_apps = test_apps,
        app_core = core,
        inputs = inputs,
        inputs_label = inputs_label,
        app_manifest = manifest,
        pubspec = pubspec,
        manifest_values = values,
        resource_files = resource_files,
        app_deps = deps,
        app_extra_deps = maven_validation,
        debug_manifest_deps = debug_manifest_deps,
        app_kwargs = kwargs,
        tags = kwargs.get("tags", []),
        native_label = native_label,
    )

    _declare_integration_tests(
        name = name,
        integration_tests = integration_tests,
        defaults = integration_test_defaults,
        app_kwargs = kwargs,
        manifest_values = values,
        test_apps = test_apps,
        app_core = core,
        inputs = inputs,
        inputs_label = inputs_label,
        app_manifest = manifest,
        pubspec = pubspec,
        resource_files = resource_files,
        app_deps = deps,
        app_extra_deps = maven_validation,
        debug_manifest_deps = debug_manifest_deps,
        tags = kwargs.get("tags", []),
        native_label = native_label,
    )

def _declare_test_apps(name, test_apps, app_core, inputs, inputs_label, app_manifest, pubspec, manifest_values, resource_files, app_deps, app_extra_deps, debug_manifest_deps, app_kwargs, tags, native_label):
    reserved = ["debug", "inputs", "manifest", "debug_manifest", "maven_repo_check", "check_test"]
    keys = sorted(test_apps.keys())
    for key in keys:
        if not key or key in reserved or key.startswith("inputs_") or key.endswith(("_core", "_manifest", "_check_test", "_assets", "_core_kernel", "_core_kernel_neutral", "_core_bundle", "_core_bundle_action")):
            fail("flutter_android_app {}: test_apps key {} is reserved or collides with a generated target suffix.".format(name, key))
        for suffix in ["_core", "_manifest", "_check_test", "_assets", "_core_kernel", "_core_kernel_neutral", "_core_bundle", "_core_bundle_action"]:
            if key + suffix in test_apps:
                fail("flutter_android_app {}: test_apps keys {} and {} generate colliding targets.".format(name, key, key + suffix))

    for key in keys:
        entry = dict(test_apps[key])
        target = name + "_" + key
        macro_fields = ["entrypoint", "srcs", "dart_defines", "app"]
        mixed_core = False
        for field in macro_fields:
            if field in entry:
                mixed_core = True
        if "core" in entry and mixed_core:
            fail("flutter_android_app {}: test_apps[{}] cannot combine `core` with entrypoint, srcs, dart_defines, or app.".format(name, key))
        if "core" not in entry:
            if app_core == None and "app" not in entry:
                fail("flutter_android_app {}: test_apps[{}] needs `app` when the app call uses prebuilt `inputs`.".format(name, key))
            if "entrypoint" not in entry:
                fail("flutter_android_app {}: test_apps[{}] needs `entrypoint` or `core`.".format(name, key))
            test_core = target + "_core"
            flutter_debug_core(
                name = test_core,
                app = entry.pop("app", app_core),
                entrypoint = entry.pop("entrypoint"),
                srcs = entry.pop("srcs", []),
                dart_defines = entry.pop("dart_defines", {}),
                tags = _test_tags(entry.get("tags", tags)),
                testonly = entry.get("testonly", True),
                visibility = entry.get("visibility", app_kwargs.get("visibility")),
                target_compatible_with = entry.get("target_compatible_with", app_kwargs.get("target_compatible_with", [])),
            )
        else:
            test_core = entry.pop("core")
            for field in macro_fields:
                entry.pop(field, None)

        entry_manifest = entry.pop("manifest", app_manifest)
        entry_values = entry.pop("manifest_values", {})
        for version_key in ["versionCode", "versionName"]:
            if version_key in entry_values:
                fail("flutter_android_app {}: test_apps[{}].manifest_values['{}'] and the pubspec both set the version.".format(name, key, version_key))
        values = dict(manifest_values)
        values.update(entry_values)
        stamped = target + "_manifest"
        test_tags = _test_tags(entry.get("tags", tags))
        flutter_android_manifest(name = stamped, manifest = entry_manifest, pubspec = pubspec, tags = test_tags)
        flutter_android_assets(name = target + "_assets", core = test_core, tags = test_tags, testonly = entry.get("testonly", True), visibility = entry.get("visibility", app_kwargs.get("visibility")))

        testonly = entry.pop("testonly", True)
        visibility = entry.pop("visibility", app_kwargs.get("visibility"))
        compatible = _debug_compatibility(entry.pop("target_compatible_with", app_kwargs.get("target_compatible_with", [])))
        entry_tags = _test_tags(entry.pop("tags", tags))
        entry_resources = entry.pop("resource_files", resource_files)
        entry_deps = entry.pop("deps", [])
        if "assets" in entry or "assets_dir" in entry:
            fail("flutter_android_app {}: `assets` and `assets_dir` are set by the macro, which declares the asset bundle of `{}`. Remove them.".format(name, inputs))
        binary_kwargs = dict(app_kwargs)
        binary_kwargs.update(entry)
        binary_kwargs["tags"] = entry_tags
        binary_kwargs["testonly"] = testonly
        binary_kwargs["visibility"] = visibility
        binary_kwargs["target_compatible_with"] = compatible
        binary_kwargs.setdefault("nocompress_extensions", _default_nocompress())
        android_binary(
            name = target,
            assets = [":" + target + "_assets"],
            assets_dir = flutter_assets_dir(":" + target + "_assets"),
            manifest = ":" + stamped,
            manifest_values = values,
            resource_files = entry_resources,
            deps = app_deps + entry_deps + [inputs_label] + debug_manifest_deps + app_extra_deps,
            **binary_kwargs
        )
        flutter_apk_check(name = target + "_check_test", binary = ":" + target, native = [native_label], tags = entry_tags, visibility = visibility, testonly = testonly)

def _declare_integration_tests(name, integration_tests, defaults, app_kwargs, manifest_values, test_apps, app_core, inputs, inputs_label, app_manifest, pubspec, resource_files, app_deps, app_extra_deps, debug_manifest_deps, tags, native_label):
    if "shard_count" in defaults:
        fail("flutter_android_app {}: shard_count is not supported for integration_tests.".format(name))
    if type(integration_tests) == "list":
        entries = {label: {} for label in integration_tests}
    elif type(integration_tests) == "dict":
        entries = integration_tests
    else:
        fail("flutter_android_app {}: integration_tests must be a list or dict.".format(name))

    names = {}
    apk_entries = {}
    for label_text, overrides in entries.items():
        label = native.package_relative_label(label_text)
        if label.name in names and names[label.name] != label:
            fail("flutter_android_app {}: integration tests {} and {} have the same target name {}; generated APK and runner names would collide.".format(name, names[label.name], label, label.name))
        names[label.name] = label
        if label.name in test_apps:
            fail("flutter_android_app {}: integration test {} collides with test_apps key {}.".format(name, label, label.name))
        if type(overrides) != "dict":
            fail("flutter_android_app {}: integration_tests[{}] must have a dict of attributes.".format(name, label))
        if "shard_count" in overrides:
            fail("flutter_android_app {}: shard_count is not supported for integration test {}.".format(name, label))
        apk_entries[label.name] = {"core": str(label)}

    if apk_entries:
        _declare_test_apps(
            name = name,
            test_apps = apk_entries,
            app_core = app_core,
            inputs = inputs,
            inputs_label = inputs_label,
            app_manifest = app_manifest,
            pubspec = pubspec,
            manifest_values = manifest_values,
            resource_files = resource_files,
            app_deps = app_deps,
            app_extra_deps = app_extra_deps,
            debug_manifest_deps = debug_manifest_deps,
            app_kwargs = app_kwargs,
            tags = tags,
            native_label = native_label,
        )

    for label_text, overrides in entries.items():
        label = native.package_relative_label(label_text)
        options = dict(defaults)
        options.update(overrides)
        if "shard_count" in options:
            fail("flutter_android_app {}: shard_count is not supported for integration test {}.".format(name, label))
        test_tags = list(options.pop("tags", ["manual", "external", "exclusive"]))
        for tag in ["manual", "external", "exclusive"]:
            if tag not in test_tags:
                test_tags.append(tag)
        test_options = options.pop("target_compatible_with", app_kwargs.get("target_compatible_with", []))
        flutter_android_integration_test(
            name = name + "_" + label.name + "_test",
            apk = ":" + name + "_" + label.name,
            integration_test = str(label),
            package = manifest_values["applicationId"],
            activity = manifest_values["applicationId"] + ".MainActivity",
            tags = test_tags,
            target_compatible_with = _debug_compatibility(test_options),
            **options
        )

def _test_tags(tags):
    out = list(tags)
    for tag in ["manual", _TEST_APK_TAG]:
        if tag not in out:
            out.append(tag)
    return out

def _debug_compatibility(extra):
    return select({
        _MODE_DEBUG: extra,
        "//conditions:default": extra + [_INCOMPATIBLE],
    })
