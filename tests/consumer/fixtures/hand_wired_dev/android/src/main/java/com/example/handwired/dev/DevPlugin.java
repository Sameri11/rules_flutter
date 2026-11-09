package com.example.handwired.dev;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import org.apache.commons.lang3.StringUtils;

public final class DevPlugin implements FlutterPlugin {
  private String normalized;

  @Override
  public void onAttachedToEngine(FlutterPluginBinding binding) {
    normalized = StringUtils.upperCase("dev");
  }

  @Override
  public void onDetachedFromEngine(FlutterPluginBinding binding) {
    normalized = null;
  }
}
