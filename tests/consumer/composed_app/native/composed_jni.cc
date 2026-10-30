#include <jni.h>

// The app's own JNI library. It is a shared object that the APK loads, so it
// must export JNI_OnLoad under C linkage.
extern "C" JNIEXPORT jint JNI_OnLoad(JavaVM*, void*) { return JNI_VERSION_1_6; }
