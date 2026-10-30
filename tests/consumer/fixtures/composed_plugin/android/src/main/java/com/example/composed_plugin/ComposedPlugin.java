package com.example.composed_plugin;

import io.flutter.embedding.engine.plugins.FlutterPlugin;

public final class ComposedPlugin implements FlutterPlugin {
  @Override
  public void onAttachedToEngine(FlutterPlugin.FlutterPluginBinding binding) {
    android.util.Log.i("ComposedPlugin", "registered");
  }

  @Override
  public void onDetachedFromEngine(FlutterPlugin.FlutterPluginBinding binding) {}
}
