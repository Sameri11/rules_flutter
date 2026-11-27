def _flutter_sdk_missing_impl(ctx):
    fail(ctx.attr.message)

flutter_sdk_missing = rule(
    implementation = _flutter_sdk_missing_impl,
    attrs = {
        "message": attr.string(mandatory = True),
    },
)
