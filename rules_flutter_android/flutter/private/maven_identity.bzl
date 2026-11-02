"""Analysis-time identity for a project's Maven repository."""

load("@rules_java//java:defs.bzl", "java_common")

FlutterMavenRepositoryInfo = provider(
    doc = "The canonical Maven repository selected by a Flutter plugin project.",
    fields = {"repo_name": "Canonical Bzlmod repository name."},
)

def _maven_repository_impl(ctx):
    return [
        FlutterMavenRepositoryInfo(repo_name = ctx.attr.maven_repo.label.repo_name),
        DefaultInfo(files = depset()),
    ]

flutter_maven_repository = rule(
    implementation = _maven_repository_impl,
    attrs = {"maven_repo": attr.label(mandatory = True)},
)

def _maven_repository_check_impl(ctx):
    project_repo = ctx.attr.project[FlutterMavenRepositoryInfo].repo_name
    supplied_repo = ctx.attr.maven_repo.label.repo_name
    if project_repo != supplied_repo:
        # buildifier: disable=canonical-repository
        fail("{}: maven_repo resolves to @@{} but the plugin project uses @@{}".format(
            ctx.label,
            supplied_repo,
            project_repo,
        ))
    return [
        java_common.merge([]),
        DefaultInfo(files = depset()),
    ]

_flutter_maven_repository_check = rule(
    implementation = _maven_repository_check_impl,
    attrs = {
        "project": attr.label(mandatory = True, providers = [FlutterMavenRepositoryInfo]),
        "maven_repo": attr.label(mandatory = True),
    },
)

def check_flutter_maven_repository(name, project, maven_repo, tags = []):
    """Declares a check that an explicit Maven label matches its project."""
    _flutter_maven_repository_check(
        name = name,
        project = project,
        maven_repo = maven_repo,
        tags = tags,
    )
