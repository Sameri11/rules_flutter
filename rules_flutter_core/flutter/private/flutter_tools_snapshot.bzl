"""Build the Flutter tools kernel from its locked source closure."""

visibility(["//flutter"])

def _kernel_snapshot_impl(ctx):
    out = ctx.actions.declare_file(ctx.label.name + ".dill")
    inputs = depset(
        direct = [
            ctx.file.dartaotruntime,
            ctx.file.frontend_server,
            ctx.file.vm_platform,
            ctx.file.dart,
            ctx.file.framework_tools,
            ctx.file.package_config,
        ],
        transitive = [target[DefaultInfo].files for target in ctx.attr.inputs],
    )
    sdk_root = ctx.file.dart.dirname + "/dart-sdk/"
    ctx.actions.run_shell(
        inputs = inputs,
        tools = [ctx.file.dartaotruntime, ctx.file.frontend_server],
        outputs = [out],
        command = "\"{runtime}\" \"{frontend_server}\" --target=vm --sdk-root=\"{sdk_root}\" --platform=../vm_platform_strong.dill --filesystem-root . --filesystem-scheme org-dartlang-root --packages=org-dartlang-root:///{package_config} --no-print-incremental-dependencies --output-dill=\"{out}\" org-dartlang-root:///{framework_tools}".format(
            runtime = ctx.file.dartaotruntime.path,
            frontend_server = ctx.file.frontend_server.path,
            sdk_root = sdk_root,
            package_config = ctx.file.package_config.path,
            out = out.path,
            framework_tools = ctx.file.framework_tools.path,
        ),
        mnemonic = "FlutterToolsKernel",
    )
    return [DefaultInfo(files = depset([out]))]

flutter_tools_kernel = rule(
    implementation = _kernel_snapshot_impl,
    attrs = {
        "dart": attr.label(mandatory = True, allow_single_file = True),
        "dartaotruntime": attr.label(mandatory = True, allow_single_file = True),
        "frontend_server": attr.label(mandatory = True, allow_single_file = True),
        "vm_platform": attr.label(mandatory = True, allow_single_file = True),
        "framework_tools": attr.label(mandatory = True, allow_single_file = True),
        "package_config": attr.label(mandatory = True, allow_single_file = True),
        "inputs": attr.label_list(allow_files = True),
    },
)
