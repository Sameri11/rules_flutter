// Test-kernel driver: compiles one test kernel with frontend_server's argument shape.
//
// `dart driver.dill <frontend_server args>` takes the arguments a test kernel is compiled with
// (--import-dill, --split-output-by-packages, --no-embed-source-text, -D, ...) and writes the
// same bytes frontend_server does, without running it. The seed's libraries are reused through
// IncrementalKernelGenerator.fromComponent, and the per-package pieces are joined, main first.
//
// Built by frontend_server with -Dsdk_hash=<Dart revision[:10]>. The driver refuses to run unless
// that define equals the import dill's SDK hash, and the output must carry the same hash.
import 'dart:io';
import 'dart:typed_data';

import 'package:front_end/src/api_prototype/incremental_kernel_generator.dart'
    show IncrementalKernelGenerator;
import 'package:front_end/src/api_unstable/vm.dart'
    show CfeDiagnosticMessage, CfeSeverity, CompilerOptions, resolveInputUri;
import 'package:kernel/ast.dart' show Component, Library, Source;
import 'package:kernel/binary/ast_from_binary.dart' show BinaryBuilder;
import 'package:kernel/binary/ast_to_binary.dart' show BinaryPrinter;
import 'package:kernel/canonical_name.dart' show CanonicalName;
import 'package:vm/kernel_front_end.dart'
    show
        KernelCompilationResults,
        createFrontEndFileSystem,
        createFrontEndTarget,
        sortComponent,
        writeOutputSplitByPackages;

const _sdkHashOffset = 8;
const _sdkHashLength = 10;
const _sdkHashDefine = String.fromEnvironment('sdk_hash');

/// frontend_server's arguments, parsed. Flags that only the frontend's batch path reads are
/// accepted and ignored: the driver always omits the platform and writes the split output.
class _Args {
  String? sdkRoot;
  String? packages;
  String? output;
  String? entry;
  bool trackWidgetCreation = false;
  final roots = <String>[];
  final imports = <String>[];
  final defines = <String, String>{};

  _Args.parse(List<String> argv) {
    for (var i = 0; i < argv.length; i++) {
      final a = argv[i];
      String value() {
        if (i + 1 >= argv.length) throw FormatException('test_kernel_driver: $a needs a value');
        return argv[++i];
      }

      if (a.startsWith('-D')) {
        final eq = a.indexOf('=');
        if (eq < 0) throw FormatException('test_kernel_driver: $a needs =value');
        defines[a.substring(2, eq)] = a.substring(eq + 1);
      } else if (a == '--sdk-root') {
        sdkRoot = value();
      } else if (a == '--packages') {
        packages = value();
      } else if (a == '--filesystem-root') {
        roots.add(value());
      } else if (a == '--filesystem-scheme') {
        if (value() != 'org-dartlang-root') throw FormatException('test_kernel_driver: unsupported scheme');
      } else if (a == '--import-dill') {
        imports.add(value());
      } else if (a == '--output-dill') {
        output = value();
      } else if (a == '--target') {
        if (value() != 'flutter') throw FormatException('test_kernel_driver: only --target flutter');
      } else if (a == '--track-widget-creation') {
        trackWidgetCreation = true;
      } else if (const {
        '--enable-asserts',
        '--no-link-platform',
        '--no-print-incremental-dependencies',
        '--split-output-by-packages',
        '--no-embed-source-text',
      }.contains(a)) {
        // Implied by the one-shot output below.
      } else if (a.startsWith('--')) {
        throw FormatException('test_kernel_driver: unsupported flag $a');
      } else if (entry == null) {
        entry = a;
      } else {
        throw FormatException('test_kernel_driver: more than one entrypoint');
      }
    }
  }

  String get(String? v, String flag) => v ?? (throw FormatException('test_kernel_driver: expected $flag'));
}

String _hex(Uint8List bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List _sdkHash(String path) {
  final file = File(path).openSync();
  try {
    file.setPositionSync(_sdkHashOffset);
    return file.readSync(_sdkHashLength);
  } finally {
    file.closeSync();
  }
}

Component _load(Uint8List bytes, CanonicalName root, String filename, dynamic target) {
  final c = target.configureComponent(Component(nameRoot: root)) as Component;
  BinaryBuilder(bytes, filename: filename, disableLazyReading: false).readComponent(c);
  return c;
}

Future<void> main(List<String> argv) async {
  final a = _Args.parse(argv);
  final sdkRoot = Uri.directory(Directory(a.get(a.sdkRoot, '--sdk-root')).absolute.path);
  final output = a.get(a.output, '--output-dill');
  final entry = a.get(a.entry, 'entrypoint');
  if (a.imports.length != 1) {
    throw FormatException('test_kernel_driver: exactly one --import-dill is required');
  }
  final importPath = a.imports.single;
  // Checked before any kernel read: the reader's own check fails with an opaque trace.
  final importHash = String.fromCharCodes(_sdkHash(importPath));
  if (_sdkHashDefine != importHash) {
    stderr.writeln(
      "test_kernel_driver: -Dsdk_hash is '$_sdkHashDefine' but the import dill's SDK hash is "
      "'$importHash'; build the driver with -Dsdk_hash set to the SDK's Dart revision.",
    );
    exit(1);
  }
  // dynamic: the target's API is the SDK's own, and its null-safe return type gets in the way.
  final dynamic target = createFrontEndTarget(
    'flutter',
    trackCreationLocations: a.trackWidgetCreation,
    supportMirrors: true,
    includeUnsupportedPlatformLibraryStubs: false,
    constKeepLocalsIndicator: true,
  );

  final root = CanonicalName.root();
  final platform = _load(
    File.fromUri(sdkRoot.resolve('platform_strong.dill')).readAsBytesSync(),
    root,
    '$sdkRoot/platform_strong.dill',
    target,
  );
  final deps = _load(File(importPath).readAsBytesSync(), root, importPath, target);
  final seedLibs = [...platform.libraries, ...deps.libraries];
  final seedSources = {...platform.uriToSource, ...deps.uriToSource};
  final seedSet = {...seedLibs};

  final errors = <String>[];
  final options = CompilerOptions()
    ..sdkRoot = sdkRoot
    ..fileSystem = createFrontEndFileSystem(
      'org-dartlang-root',
      [for (final r in a.roots) Directory(r).absolute.path],
    )
    ..packagesFileUri = Uri.parse(a.get(a.packages, '--packages'))
    ..sdkSummary = sdkRoot.resolve('platform_strong.dill')
    ..embedSourceText = false
    ..target = target
    ..onDiagnostic = (CfeDiagnosticMessage m) {
      if (m.severity == CfeSeverity.error || m.severity == CfeSeverity.internalProblem) {
        errors.addAll(m.plainTextFormatted);
      }
    }
    ..environmentDefines = target.updateEnvironmentDefines(Map.of(a.defines));

  final work = '$output.work';
  Directory(work).createSync(recursive: true);
  try {
    final source = resolveInputUri(entry);
    final gen = IncrementalKernelGenerator.fromComponent(
      options,
      [source],
      Component(libraries: List<Library>.of(seedLibs), uriToSource: Map<Uri, Source>.of(seedSources)),
    );
    final res = await gen.computeDelta(entryPoints: [source]);
    if (errors.isNotEmpty) {
      stderr.writeln(errors.join('\n'));
      exitCode = 1;
      return;
    }
    final results = KernelCompilationResults.named(
      component: res.component,
      loadedLibraries: seedSet,
      classHierarchy: res.classHierarchy,
      coreTypes: res.coreTypes,
    );

    final full = '$work/kernel.dill';
    sortComponent(res.component);
    final sink = File(full).openWrite();
    BinaryPrinter(
      sink,
      libraryFilter: (lib) => !seedSet.contains(lib),
      includeSources: false,
    ).writeComponentFile(res.component);
    await sink.close();
    await writeOutputSplitByPackages(source, options, results, full);

    final join = File(output).openWrite();
    join.add(File('$full-main.dilp').readAsBytesSync());
    for (final pkg in File('$full-packages').readAsLinesSync()) {
      if (pkg != 'main' && pkg.isNotEmpty) {
        join.add(File('$full-$pkg.dilp').readAsBytesSync());
      }
    }
    await join.close();
  } finally {
    Directory(work).deleteSync(recursive: true);
  }

  final got = _hex(_sdkHash(output));
  final want = _hex(_sdkHash(importPath));
  if (got != want) {
    stderr.writeln(
      "test_kernel_driver: the output's SDK hash $got differs from the import dill's $want; "
      'the driver was built without the matching -Dsdk_hash',
    );
    exit(1);
  }
}
