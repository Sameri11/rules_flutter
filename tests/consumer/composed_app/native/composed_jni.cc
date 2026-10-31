#include <jni.h>

// The app's own JNI library, linked into the APK's library. JNI_OnLoad runs when it
// loads; the plugin's native method is exported under its JNI name. The underscore in
// the package name is spelled _1 in that name.
extern "C" JNIEXPORT jint JNI_OnLoad(JavaVM*, void*) { return JNI_VERSION_1_6; }

extern "C" JNIEXPORT jint JNICALL
Java_com_example_composed_1plugin_ComposedPlugin_nativeMarker(JNIEnv*, jclass) {
  return 42;
}
