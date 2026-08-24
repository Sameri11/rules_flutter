"""An unmatched dependency recipe that must never be loaded.

`external_app` registers `absent_package`, which `consumer_test` does not
depend on. `_flutter_plugins_impl` must report and discard it. The impossible
symbol below turns any attempted load into a test failure.
"""

load("@flutter_bazel//tools/flutter:recipe.bzl", "this_symbol_does_not_exist")

# Keep the alias so buildifier treats the deliberately invalid import as used.
absent_package_recipe = this_symbol_does_not_exist
