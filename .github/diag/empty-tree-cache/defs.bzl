"""Actions whose only difference is the size of the file they write."""

def _write(ctx, out):
    ctx.actions.run_shell(
        outputs = [out],
        arguments = [ctx.attr.content, out.path + ("/payload" if out.is_directory else "")],
        command = "printf '%s' \"$1\" > \"$2\"",
        mnemonic = "DiagTree" if out.is_directory else "DiagFile",
        # DIAG_SALT (--action_env) gives every workflow run fresh action keys.
        use_default_shell_env = True,
    )
    return [DefaultInfo(files = depset([out]))]

def _tree_impl(ctx):
    return _write(ctx, ctx.actions.declare_directory(ctx.label.name))

def _file_impl(ctx):
    return _write(ctx, ctx.actions.declare_file(ctx.label.name))

diag_tree = rule(implementation = _tree_impl, attrs = {"content": attr.string()})
diag_file = rule(implementation = _file_impl, attrs = {"content": attr.string()})
