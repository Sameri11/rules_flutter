package com.example.composed_plugin;

import io.flutter.embedding.engine.plugins.FlutterPlugin;

public final class ComposedPlugin implements FlutterPlugin {
  static {
    System.loadLibrary("apk");
  }

  private static native int nativeMarker();

  @Override
  public void onAttachedToEngine(FlutterPlugin.FlutterPluginBinding binding) {
    android.util.Log.i("ComposedPlugin", "registered");
    android.util.Log.i("ComposedPlugin", "jni " + nativeMarker());
  }

  @Override
  public void onDetachedFromEngine(FlutterPlugin.FlutterPluginBinding binding) {}
}
