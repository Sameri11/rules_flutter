"""Maven coordinate helpers shared by the embedding and the plugin generator.

Both need to turn `group:artifact:version` into the target rules_jvm_external
generates for it, and both feed the same artifact list, so the mangling and the
version comparison live in one place rather than being reimplemented per caller.
"""

def maven_label(coordinate, repo):
    """`group:artifact[:version]` -> the target rules_jvm_external generates."""
    parts = coordinate.split(":")
    mangled = (parts[0] + "_" + parts[1]).replace(".", "_").replace("-", "_")
    return "{}//:{}".format(repo, mangled)

def version_key(version):
    """Sortable form of a Maven version. Numeric parts compare as numbers.

    Args:
      version: a coordinate's version field, e.g. `1.4.1` or `1.0-rc2`.

    Returns:
      A list comparable with `>` against another version's key.
    """
    parts = []
    for chunk in version.replace("-", ".").split("."):
        if chunk.isdigit():
            parts.append(int(chunk))
        else:
            # A qualifier (rc, alpha, SNAPSHOT) sorts below any numeric part.
            parts.append(-1)
    return parts

def highest_versions(coordinates):
    """One coordinate per group:artifact, keeping the highest version.

    Highest-wins is Gradle's conflict rule, so resolving this way reproduces
    what the same set of plugins would have got from a Gradle build.

    This is applied to the *whole* artifact list -- the embedding's own
    dependencies and every plugin's -- before it reaches maven.install. Doing it
    per-source instead is what previously let a plugin downgrade
    androidx.exifinterface from the 1.4.1 the embedding declares to 1.3.7:
    two install tags merged into one repository, and the later one simply won.

    Args:
      coordinates: `group:artifact:version` strings, in any order.

    Returns:
      Those coordinates sorted, one per group:artifact.
    """
    best = {}
    for coordinate in coordinates:
        group, artifact, version = coordinate.split(":")
        key = group + ":" + artifact
        if key not in best or version_key(version) > version_key(best[key]):
            best[key] = version
    return [k + ":" + v for k, v in sorted(best.items())]
