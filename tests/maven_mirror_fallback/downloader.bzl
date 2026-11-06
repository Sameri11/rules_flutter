load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_file")

def _fixture_impl(_ctx):
    http_file(
        name = "pinned_file",
        urls = [
            "http://127.0.0.1:18765/maven2/junit/junit/4.13.2/junit-4.13.2.jar",
            "https://maven-central.storage-download.googleapis.com/maven2/junit/junit/4.13.2/junit-4.13.2.jar",
        ],
        sha256 = "8e495b634469d64fb8acfa3495a065cbacc8a0fff55ce1e31007be4c16dc57d3",
        downloaded_file_path = "junit.jar",
    )

fixture = module_extension(implementation = _fixture_impl)
