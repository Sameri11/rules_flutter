"""A stock android_binary over a flutter_core artifact's Android inputs, with Flutter's defaults.

`flutter_android_app` declares the binary and the glue a standard-layout Flutter app
needs: the version stamp, the resources, the debug manifest, the native libraries
stored uncompressed, and the APK check. Each default is an argument. Variants of
one app share an inputs target through `inputs`, so the engine strip, the AOT
library and the asset copy are built once.
"""

load("@rules_android//rules:rules.bzl", "android_binary", "android_library")
load(":abis.bzl", "MIN_SDK")
load(":android.bzl", "flutter_android_manifest", "flutter_assets_dir")
load(":android_inputs_rules.bzl", "flutter_android_inputs")
load(":apk_check.bzl", "flutter_apk_check")
load("@rules_flutter_core//flutter:defs.bzl", "flutter_debug_core")
load(":maven_identity.bzl", "check_flutter_maven_repository")

# Mirrors android.bzl's _MANIFEST_VALUES, which goes with the wrapper.
_MANIFEST_VALUES = {
    "applicationName": "io.flutter.app.FlutterApplication",
    "minSdkVersion": str(MIN_SDK),
    "targetSdkVersion": "36",
}

_MODE_DEBUG = Label("@rules_flutter_core//flutter:mode_debug")
_MODE_RELEASE = Label("@rules_flutter_core//flutter:mode_release")

# Sentinels no caller can pass by accident. A string compare would also match a
# consumer who writes the default path explicitly and expects it to be required.
_UNSET = struct(sentinel = "plugins")
_DEFAULT_DEBUG_MANIFEST = struct(sentinel = "debug_manifest")

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
        test_apps = {},
        apk_check = True,
        **kwargs):
    """A stock android_binary `name` with Flutter's defaults for a standard layout.

    Declares `<name>_inputs` from `core` and `plugins` unless `inputs` names an
    existing flutter_android_inputs target. The macro's own targets carry the
    caller's tags plus `manual`. `<name>` and `<name>_check_test` carry the caller's
    tags and visibility.

    Args:
      name: the APK's target name.
      core: the flutter_core target the app runs. Required without `inputs`.
      inputs: a flutter_android_inputs target to reuse, for variants of one app.
        It must be declared by flutter_android_inputs: the macro derives
        `<inputs>_bundle`, `<inputs>_native` and `<inputs>_pubspec` from its name.
        Its `core` and `plugins` are the ones it was declared with, and it must be
        visible from this package.
      plugins: the plugin repository, e.g. "@flutter_plugins", or None for an app
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
      test_apps: a dict of test APK suffixes to `entrypoint`, optional `srcs`
        and `dart_defines`. Requires `core` and `plugins` in this call. Each
        test uses the app's manifest values, resources, deps and plugin config.
      deps: the app's own targets. The inputs target is appended.
      **kwargs: forwarded to android_binary, and tags and visibility also to
        `<name>_check_test`. `assets` and `assets_dir` are set by the macro and
        refused here.
    """

    if test_apps and (inputs != None or core == None or plugins == _UNSET):
        fail("flutter_android_app {}: `test_apps` requires `core` and `plugins` in this call, not `inputs`.".format(name))

    deps = kwargs.pop("deps", [])
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

    kwargs.setdefault("nocompress_extensions", [".so"])
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
    for suffix, test_app in test_apps.items():
        test_name = name + "_" + suffix
        test_core = test_name + "_core"
        test_inputs = test_name + "_inputs"
        flutter_debug_core(
            name = test_core,
            app = core,
            entrypoint = test_app["entrypoint"],
            srcs = test_app.get("srcs", []),
            dart_defines = test_app.get("dart_defines", {}),
            tags = internal_tags,
        )
        flutter_android_inputs(
            name = test_inputs,
            core = ":" + test_core,
            plugins = plugins,
            maven_repo = maven_repo,
            tags = internal_tags,
        )
        test_inputs_label = native.package_relative_label(":" + test_inputs)
        test_bundle = test_inputs_label.same_package_label(test_inputs_label.name + "_bundle")
        test_kwargs = dict(kwargs)
        test_kwargs["tags"] = internal_tags
        test_kwargs.setdefault("nocompress_extensions", [".so"])
        android_binary(
            name = test_name,
            assets = [test_bundle],
            assets_dir = flutter_assets_dir(assets = test_bundle),
            manifest = ":" + name + "_manifest",
            manifest_values = values,
            resource_files = resource_files,
            deps = deps + [test_inputs_label] + debug_manifest_deps + maven_validation,
            **test_kwargs
        )

    if apk_check:
        flutter_apk_check(
            name = name + "_check_test",
            binary = ":" + name,
            native = [native_label],
            tags = kwargs.get("tags", []),
            visibility = kwargs.get("visibility"),
        )
