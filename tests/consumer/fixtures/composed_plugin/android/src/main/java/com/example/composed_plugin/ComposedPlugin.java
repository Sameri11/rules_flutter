package com.example.composed_plugin;

import io.flutter.embedding.engine.plugins.FlutterPlugin;

public final class ComposedPlugin implements FlutterPlugin {

  private static native int nativeMarker();
  private static native int recipeMarker();
  private static native int aarMarker();

  @Override
  public void onAttachedToEngine(FlutterPlugin.FlutterPluginBinding binding) {
    System.loadLibrary("marker_dependency");
    System.loadLibrary("recipe_marker");
    System.loadLibrary("aar_native");
    String packageName = binding.getApplicationContext().getPackageName();
    String library = packageName.endsWith(".variant") ? "apk_variant"
        : packageName.endsWith(".override") ? "apk_override" : "apk";
    System.loadLibrary(library);
    android.util.Log.i("ComposedPlugin", "registered");
    android.util.Log.i("ComposedPlugin", "jni " + nativeMarker());
    android.util.Log.i("ComposedPlugin", "recipe " + recipeMarker());
    android.util.Log.i("ComposedPlugin", "aar " + aarMarker());
  }

  @Override
  public void onDetachedFromEngine(FlutterPlugin.FlutterPluginBinding binding) {}
}
