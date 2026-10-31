// The AAR's only native library. It is packaged for arm64-v8a alone, so the
// other splits of the composed app receive no AAR natives.
extern "C" int composed_aar_native_version() { return 1; }
