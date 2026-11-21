# Changelog

## Unreleased

- CI now tests Flutter 3.50.1 (Dart 3.14.0). Flutter 3.47.3 is no longer pinned for the host test driver or metadata parser. It uses `frontend_server` to compile test kernels and falls back to the newest pinned metadata parser with a warning.
- Generated Android apps now register plugins after their dependencies on all Flutter SDK versions. Unrelated plugins are ordered alphabetically. Apps that relied on alphabetical registration despite declaring plugin dependencies may observe a different order. Hand-written registrants keep their existing behavior.
