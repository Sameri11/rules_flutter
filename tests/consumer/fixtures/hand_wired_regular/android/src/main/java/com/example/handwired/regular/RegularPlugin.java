package com.example.handwired.regular;

import com.google.gson.Gson;
import io.flutter.embedding.engine.plugins.FlutterPlugin;

public final class RegularPlugin implements FlutterPlugin {
  private Gson gson;

  @Override
  public void onAttachedToEngine(FlutterPluginBinding binding) {
    gson = new Gson();
    gson.toJson("regular");
  }

  @Override
  public void onDetachedFromEngine(FlutterPluginBinding binding) {
    gson = null;
  }
}
