// The AAR supplies a native library for every ABI.
#include <jni.h>

extern "C" int composed_aar_native_version() { return 1; }

extern "C" JNIEXPORT jint JNICALL
Java_com_example_composed_1plugin_ComposedPlugin_aarMarker(JNIEnv*, jclass) {
  return composed_aar_native_version();
}
