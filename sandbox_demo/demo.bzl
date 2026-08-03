"""A rule whose action reaches for a file it never declared as an input.

It logs what it saw rather than failing, so the same target reports whether the
undeclared sibling was visible: sandboxed it is not, local it is.
"""

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
