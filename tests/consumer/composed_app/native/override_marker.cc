#include <jni.h>

extern "C" JNIEXPORT jint JNICALL
Java_com_example_cmake_1plugin_CmakePlugin_nativeMarker(JNIEnv*, jclass) {
  return 99;
}
