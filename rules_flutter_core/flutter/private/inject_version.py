"""Write an app's version into AndroidManifest.xml.

`versionCode` and `versionName` reach an android_binary through
`manifest_values`, which is a load-time dict -- so a version that lives in a
file cannot get there. This writes it into the manifest instead.

The values arrive already parsed, from read_pubspec.py: this step depends on
the two facts rather than on the whole pubspec, so an edit elsewhere in the
pubspec does not repackage the APK's resources.

The edit is targeted at the `<manifest>` open tag rather than done by parsing
and re-serialising the document. A round trip through an XML library rewrites
the namespace prefix and discards comments, which makes the generated manifest
unreadable against the source it came from.
"""

import argparse
import re
import sys

ANDROID_NS = "http://schemas.android.com/apk/res/android"

# The open tag, up to the first `>` that is not inside an attribute value.
_MANIFEST_TAG = re.compile(r"<manifest\b((?:[^>\"']|\"[^\"]*\"|'[^']*')*)>")


def fail(message):
    sys.exit("inject_version: " + message)


def read_fact(path):
    """A value read_pubspec wrote, without its trailing newline."""
    with open(path) as handle:
        return handle.read().strip()


def read_manifest(path):
    """The manifest verbatim -- trailing newline included, so the only
    difference from the source is the attributes injected below."""
    with open(path) as handle:
        return handle.read()


def android_prefix(attributes, path):
    """The prefix bound to the Android namespace in the manifest tag."""
    match = re.search(
        r"xmlns:([A-Za-z_][\w.-]*)\s*=\s*[\"']{}[\"']".format(re.escape(ANDROID_NS)),
        attributes,
    )
    if not match:
        fail(
            "{}: the <manifest> tag declares no prefix for {}. An injected "
            "attribute would be namespaceless and aapt would ignore it.".format(
                path,
                ANDROID_NS,
            ),
        )
    return match.group(1)


def inject(path, text, name, code):
    """The manifest text with versionCode and versionName on <manifest>."""
    match = _MANIFEST_TAG.search(text)
    if not match:
        fail("{}: no <manifest> open tag.".format(path))

    attributes = match.group(1)
    prefix = android_prefix(attributes, path)

    # Two sources for one value is the failure this rule exists to prevent, so
    # a manifest that already carries either attribute is an error rather than
    # something to overwrite.
    for attribute in ("versionCode", "versionName"):
        if re.search(r"\b{}:{}\s*=".format(re.escape(prefix), attribute), attributes):
            fail(
                "{}: <manifest> already declares {}:{}. Remove it, or drop "
                "`pubspec` and keep the manifest as the source.".format(
                    path,
                    prefix,
                    attribute,
                ),
            )

    injected = '{attrs} {p}:versionCode="{code}" {p}:versionName="{name}"'.format(
        attrs = attributes.rstrip(),
        p = prefix,
        code = code,
        name = name,
    )
    return "{}<manifest{}>{}".format(
        text[:match.start()],
        injected,
        text[match.end():],
    )


def main():
    parser = argparse.ArgumentParser(description = __doc__)
    parser.add_argument("--version-name", required = True)
    parser.add_argument("--version-code", required = True)
    parser.add_argument("--manifest", required = True)
    parser.add_argument("--out", required = True)
    args = parser.parse_args()

    with open(args.out, "w") as handle:
        handle.write(inject(
            args.manifest,
            read_manifest(args.manifest),
            read_fact(args.version_name),
            read_fact(args.version_code),
        ))


if __name__ == "__main__":
    main()
