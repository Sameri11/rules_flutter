package com.example.consumer;

import com.example.build_config_plugin.BuildConfigPlugin;

public final class BuildConfigValues {
  public static void main(String[] args) {
    System.out.print(BuildConfigPlugin.values());
  }

  private BuildConfigValues() {}
}
