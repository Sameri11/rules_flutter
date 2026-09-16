package com.example.build_config_plugin;

import io.flutter.embedding.engine.plugins.FlutterPlugin;

public final class BuildConfigPlugin implements FlutterPlugin {
  public static String values() {
    return BuildConfig.DEBUG + ":" + BuildConfig.BUILD_TYPE + ":" +
        BuildConfig.LIBRARY_PACKAGE_NAME + ":" + BuildConfig.STRING_VALUE + ":" +
        BuildConfig.VERSION + ":" + BuildConfig.BOOLEAN_VALUE + ":" +
        BuildConfig.BYTE_VALUE + ":" + BuildConfig.SHORT_VALUE + ":" +
        BuildConfig.INT_VALUE + ":" + BuildConfig.LONG_VALUE + ":" +
        BuildConfig.FLOAT_VALUE + ":" + BuildConfig.DOUBLE_VALUE;
  }

  @Override
  public void onAttachedToEngine(FlutterPlugin.FlutterPluginBinding binding) {}

  @Override
  public void onDetachedFromEngine(FlutterPlugin.FlutterPluginBinding binding) {}
}
