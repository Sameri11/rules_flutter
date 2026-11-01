package com.example.cmake_plugin;

import io.flutter.embedding.engine.plugins.FlutterPlugin;

public final class CmakePlugin implements FlutterPlugin {
  static {
    System.loadLibrary("cmake_marker");
  }

  private static native int nativeMarker();

  @Override
  public void onAttachedToEngine(FlutterPlugin.FlutterPluginBinding binding) {
    android.util.Log.i("CmakePlugin", "jni " + nativeMarker());
  }

  @Override
  public void onDetachedFromEngine(FlutterPlugin.FlutterPluginBinding binding) {}
}
