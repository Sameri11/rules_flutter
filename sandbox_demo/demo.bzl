def _impl(ctx):
    out = ctx.actions.declare_file(ctx.label.name + ".log")
    # Reads its declared input, then reaches for a sibling file it never declared.
    ctx.actions.run_shell(
        inputs = [ctx.file.declared],
        outputs = [out],
        command = """
          echo "cwd = $PWD" > {out}
          echo "--- declared:" >> {out}
          cat {dec} >> {out}
          echo "--- undeclared:" >> {out}
          cat sandbox_demo/undeclared.txt >> {out} 2>&1 || echo "NOT VISIBLE" >> {out}
        """.format(out = out.path, dec = ctx.file.declared.path),
    )
    return [DefaultInfo(files = depset([out]))]

demo = rule(
    implementation = _impl,
    attrs = {"declared": attr.label(allow_single_file = True)},
)
