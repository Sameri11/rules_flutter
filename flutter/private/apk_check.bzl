"""The APK check: an APK's native libraries must be the ones the build declared.

Packaging can drop an engine library, ship a stray one or replace one with a file
of the same name. flutter_apk_check fails the build when an ABI's lib/ entries
differ from the declared set: each split's own libraries, plus the libraries of
the AARs, library archives and linked dependencies the android_binary packages
for that split.
"""

load("@rules_android//rules:android_split_transition.bzl", "android_split_transition")
load("@rules_android//providers:providers.bzl", "AndroidBinaryNativeLibsInfo")
load(":abis.bzl", "ABIS")
load(":android_inputs_rules.bzl", "FlutterSplitNativeInfo")

_CHECKER = "//flutter/private:apk_check_tool"

# The libraries the android_binary packages for each split, from the provider. Two
# fields: the AAR and library archives (native_libs.zip, jars), whose lib/<abi>/*.so
# entries the checker reads with their CRC-32, and the files the binary links
# (lib<binary>.so, plus the shared libraries of the deps' CcInfo, Flutter's included).
# Fails closed: a missing provider, field or split key is an error, not an empty set.
def _provider_records(ctx, abis):
    if AndroidBinaryNativeLibsInfo not in ctx.attr.binary:
        fail("{}: {} does not return AndroidBinaryNativeLibsInfo, so its natives cannot be derived. flutter_apk_check needs an android_binary.".format(ctx.label, ctx.attr.binary.label))
    info = ctx.attr.binary[AndroidBinaryNativeLibsInfo]
    by_cpu = getattr(info, "transitive_native_libs_by_cpu_architecture", None)
    if by_cpu == None:
        fail("{}: AndroidBinaryNativeLibsInfo of {} has no transitive_native_libs_by_cpu_architecture.".format(ctx.label, ctx.attr.binary.label))
    linked = getattr(info, "native_libs", None)
    if linked == None:
        fail("{}: AndroidBinaryNativeLibsInfo of {} has no native_libs.".format(ctx.label, ctx.attr.binary.label))
    for split in by_cpu.keys() + linked.keys():
        # A custom Android platform names its own cpu, which no Flutter split configures.
        if split not in ABIS:
            fail("{}: the binary packages natives for split {}, which is not a stock ABI. Custom Android platform names are unsupported; use the ABI keys of flutter/private/abis.bzl.".format(ctx.label, split))
        if split not in abis:
            fail("{}: the binary packages natives for split {}, which no native split configures.".format(ctx.label, split))
    records = []
    inputs = []
    for abi in sorted(abis):
        if abi not in by_cpu or abi not in linked:
            fail("{}: AndroidBinaryNativeLibsInfo has no natives entry for split {}.".format(ctx.label, abi))
        for f in by_cpu[abi].to_list():
            records.append(["archive", abi, f.path])
            inputs.append(f)
        for f in linked[abi].to_list():
            records.append(["native", abi, f.basename, f.path])
            inputs.append(f)
    return records, inputs

def _apk_file(ctx):
    # android_binary also writes <name>_unsigned.apk; the installable one is <name>.apk.
    want = ctx.attr.binary.label.name + ".apk"
    apks = [f for f in ctx.attr.binary[DefaultInfo].files.to_list() if f.basename == want]
    if len(apks) != 1:
        fail("{}: {} must produce exactly one {}, got {}".format(ctx.label, ctx.attr.binary.label, want, [f.basename for f in ctx.attr.binary[DefaultInfo].files.to_list()]))
    return apks[0]

def _same_mode(ctx, mode, found):
    if mode == None:
        return found
    if found != mode:
        fail("{}: the splits disagree on mode ({} and {})".format(ctx.label, mode, found))
    return mode

def _native_records(ctx):
    mode = None
    records = []
    inputs = []
    abis = {}
    for platform in sorted(ctx.split_attr.native.keys()):
        for target in ctx.split_attr.native[platform]:
            info = target[FlutterSplitNativeInfo]
            if info.abi == None:
                continue
            mode = _same_mode(ctx, mode, info.mode)
            if info.abi in abis:
                fail("{}: two splits build {}".format(ctx.label, info.abi))
            abis[info.abi] = True
            records.append(["abi", info.abi])
            for f in info.libraries:
                records.append(["expect", info.abi, f.basename, f.path])
                inputs.append(f)
    return mode, records, inputs, abis

# A split with no Android ABI packages no libraries, and its placeholder fails when
# built. The check returns those placeholders instead of a verdict, so a build without
# --android_platforms fails at execution, and analysis does not fail on the missing data.
def _unconfigured(ctx):
    files = []
    for platform in sorted(ctx.split_attr.native.keys()):
        for target in ctx.split_attr.native[platform]:
            if target[FlutterSplitNativeInfo].abi == None:
                files.extend(target[DefaultInfo].files.to_list())
    return files

def _flutter_apk_check_impl(ctx):
    unconfigured = _unconfigured(ctx)
    if unconfigured:
        return [
            DefaultInfo(files = depset(unconfigured)),
            OutputGroupInfo(_validation = depset(unconfigured)),
        ]

    apk = _apk_file(ctx)
    mode, records, inputs, abis = _native_records(ctx)
    if not abis:
        fail("{}: the Android splits configure no ABI; set --android_platforms to the Android platforms to check.".format(ctx.label))
    provided, provided_inputs = _provider_records(ctx, abis)
    records = records + provided
    inputs = inputs + provided_inputs

    spec = ctx.actions.declare_file(ctx.label.name + ".spec.tsv")
    ctx.actions.write(spec, "".join([
        "\t".join(line) + "\n"
        for line in [["mode", mode]] + records
    ]))

    report = ctx.actions.declare_file(ctx.label.name + ".txt")
    ctx.actions.run(
        executable = ctx.executable._checker,
        tools = [ctx.attr._checker[DefaultInfo].files_to_run],
        arguments = [spec.path, apk.path, report.path, str(ctx.label)],
        inputs = [apk, spec] + inputs,
        outputs = [report],
        mnemonic = "FlutterApkCheck",
        progress_message = "Checking the native payload of %{label}",
    )
    return [
        DefaultInfo(files = depset([report])),
        OutputGroupInfo(_validation = depset([report])),
    ]

flutter_apk_check = rule(
    implementation = _flutter_apk_check_impl,
    doc = """Fails unless the APK's native libraries are exactly the ones the build declared.

`binary` is the android_binary whose APK is checked. Its AndroidBinaryNativeLibsInfo
names the libraries it packages for each split. `native` is the `<name>_native`
target of each flutter_android_inputs the binary depends on, read in each split.

Per ABI, lib/<abi>/ must hold exactly the declared names, each with the declared
file's CRC-32, and its .so entries must be stored, so a missing, extra, changed or
deflated library fails. Every mismatch is reported in one run. The expected set also
holds the lib/<abi>/*.so entries of each AAR and library archive the binary packages
for the split, with their CRC-32 taken from the archive. A name shipped by a file and
an archive, or by two archives with different bytes, fails.

A split with no Android ABI (no --android_platforms) makes the check's output that
split's failing placeholder, so building the check fails rather than passing unchecked.""",
    attrs = {
        "binary": attr.label(
            mandatory = True,
            doc = "The android_binary whose APK and AndroidBinaryNativeLibsInfo are checked.",
        ),
        "native": attr.label_list(
            mandatory = True,
            allow_empty = False,
            cfg = android_split_transition,
            providers = [FlutterSplitNativeInfo],
            doc = "The `<name>_native` targets of the flutter_android_inputs the binary depends on, read in each split.",
        ),
        "_checker": attr.label(default = _CHECKER, executable = True, cfg = "exec"),
    },
)
