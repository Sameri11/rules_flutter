def manifest_from_app(name, app):
    app_label = Label(app)
    native.filegroup(
        name = name,
        srcs = ["//%s:%s_manifest" % (app_label.package, app_label.name)],
    )
