import 'dart:io';

import 'package:flutter_tools/src/asset.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/platform.dart';
import 'package:flutter_tools/src/base/process.dart';
import 'package:flutter_tools/src/base/user_messages.dart';
import 'package:flutter_tools/src/build_info.dart';
import 'package:flutter_tools/src/bundle_builder.dart';
import 'package:flutter_tools/src/cache.dart';
import 'package:flutter_tools/src/context_runner.dart';
import 'package:flutter_tools/src/device.dart';
import 'package:flutter_tools/src/globals.dart' as globals;

Future<void> main(List<String> args) async {
  Cache.flutterRoot = Cache.defaultFlutterRoot(
    platform: const LocalPlatform(),
    fileSystem: globals.localFileSystem,
    userMessages: UserMessages(),
  );

  await runInContext<void>(() async {
    final AssetBundle bundle = AssetBundleFactory.instance.createBundle();
    final int result = await bundle.build(
      packageConfigPath: globals.fs.path.join(
        globals.fs.currentDirectory.path,
        '.dart_tool/package_config.json',
      ),
      includeAssetsFromDevDependencies: true,
      targetPlatform: TargetPlatform.tester,
    );
    if (result != 0) {
      throw StateError('Failed to build tester asset bundle.');
    }

    await writeBundle(
      globals.fs.directory(args.single),
      bundle.entries,
      targetPlatform: TargetPlatform.tester,
      impellerStatus: ImpellerStatus.platformDefault,
      processManager: globals.processManager,
      fileSystem: globals.fs,
      artifacts: globals.artifacts!,
      logger: globals.logger,
      projectDir: globals.fs.currentDirectory,
      buildMode: BuildMode.debug,
    );
  });
}
