// Writes the flutter_test asset bundle for the tester platform, the bundle
// `flutter test` builds (commands/test.dart, _buildTestAsset). Run from the
// staged project root with the output directory as its one argument.
//
// Native build hooks do not run here, so the bundle carries no native-library
// outputs and no NativeAssetsManifest.json.
import 'package:file/file.dart';
import 'package:process/process.dart';

import 'package:flutter_tools/src/artifacts.dart';
import 'package:flutter_tools/src/asset.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/base/platform.dart';
import 'package:flutter_tools/src/base/user_messages.dart';
import 'package:flutter_tools/src/build_info.dart';
import 'package:flutter_tools/src/bundle_builder.dart';
import 'package:flutter_tools/src/cache.dart';
import 'package:flutter_tools/src/context_runner.dart';
import 'package:flutter_tools/src/device.dart';
import 'package:flutter_tools/src/globals.dart' as globals;

// Flutter 3.50 added a required platform argument. Keep the same builder
// source compilable against SDKs that still have the previous signature.
typedef _BundleWriterWithoutPlatform = Future<void> Function(
  Directory,
  Map<String, AssetBundleEntry>, {
  required TargetPlatform targetPlatform,
  required ImpellerStatus impellerStatus,
  required ProcessManager processManager,
  required FileSystem fileSystem,
  required Artifacts artifacts,
  required Logger logger,
  required Directory projectDir,
  required BuildMode buildMode,
});

Future<void> main(List<String> args) async {
  Cache.flutterRoot = Cache.defaultFlutterRoot(
    platform: const LocalPlatform(),
    fileSystem: globals.localFileSystem,
    userMessages: UserMessages(),
  );

  await runInContext<void>(() async {
    final AssetBundle bundle = AssetBundleFactory.instance.createBundle();
    final int result = await bundle.build(
      packageConfigPath: '.dart_tool/package_config.json',
      includeAssetsFromDevDependencies: true,
      targetPlatform: TargetPlatform.tester,
    );
    if (result != 0) {
      throw StateError('Failed to build the tester asset bundle.');
    }
    final Function writer = writeBundle;
    await (Function.apply(
      writer,
      [globals.fs.directory(args.single), bundle.entries],
      {
        #targetPlatform: TargetPlatform.tester,
        #impellerStatus: ImpellerStatus.platformDefault,
        #processManager: globals.processManager,
        #fileSystem: globals.fs,
        #artifacts: globals.artifacts!,
        #logger: globals.logger,
        #projectDir: globals.fs.currentDirectory,
        #buildMode: BuildMode.debug,
        if (writer is! _BundleWriterWithoutPlatform) #platform: globals.platform,
      },
    ) as Future<void>);
  });
}
