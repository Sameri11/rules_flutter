// Test-kernel driver: compiles one test kernel with frontend_server's arguments, in process.
//
// One-shot: `dart driver.dill <args>` writes the bytes frontend_server writes for the same
// arguments (--import-dill, --split-output-by-packages, --no-embed-source-text, -D, ...). The
// import dill's libraries are reused through IncrementalKernelGenerator.fromComponent, and the
// per-package pieces are joined, main first.
//
// Worker: `dart driver.dill --persistent_worker` serves Bazel's JSON worker protocol: one
// WorkRequest per line on stdin, one WorkResponse per line on stdout, singleplex. A request reads
// only its declared inputs. They are linked into a view, kept per process and mirrored to each
// request by diff, and the file system's roots all resolve inside that view. Up to two seeds,
// one per import dill digest, stay loaded between requests.
//
// Built by frontend_server with -Dsdk_hash=<Dart revision[:10]>. The driver refuses an import dill
// whose SDK hash differs from its own, and checks the output's hash.
import 'dart:convert';
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
const _persistentFlag = '--persistent_worker';
const _seedLimit = 2;

// Accepted for frontend_server compatibility; the driver always writes the split output without
// the platform and without source text.
const _ignored = {
  '--enable-asserts',
  '--no-link-platform',
  '--no-print-incremental-dependencies',
  '--split-output-by-packages',
  '--no-embed-source-text',
};

String need(String? value, String flag) =>
    value ?? (throw FormatException('test_kernel_driver: expected $flag'));

String _join(String base, String path) => path.startsWith('/') ? path : '$base/$path';

/// `@file` arguments expand to their lines, relative to [base].
List<String> _expand(Iterable<String> args, String base) => [
  for (final a in args)
    if (a.startsWith('@') &&
        !a.startsWith('@@') &&
        File(_join(base, a.substring(1))).existsSync())
      ...File(_join(base, a.substring(1))).readAsLinesSync()
    else
      a,
];

class _Args {
  String? sdkRoot;
  String? packages;
  String? output;
  String? entryScheme;
  String? entryPath;
  String? packageNameFile;
  String? errorHint;
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
        if (value() != 'org-dartlang-root') {
          throw FormatException('test_kernel_driver: unsupported scheme');
        }
      } else if (a == '--import-dill') {
        imports.add(value());
      } else if (a == '--output-dill') {
        output = value();
      } else if (a == '--target') {
        if (value() != 'flutter') throw FormatException('test_kernel_driver: only --target flutter');
      } else if (a == '--entry-scheme') {
        entryScheme = value();
      } else if (a == '--entry-path') {
        entryPath = value();
      } else if (a == '--package-name-file') {
        packageNameFile = value();
      } else if (a == '--error-hint') {
        errorHint = value();
      } else if (a == '--track-widget-creation') {
        trackWidgetCreation = true;
      } else if (!_ignored.contains(a)) {
        throw FormatException('test_kernel_driver: unsupported argument $a');
      }
    }
  }
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

/// The libraries a compile starts from: the platform and one import dill.
class _Seed {
  final List<Library> libs;
  final Map<Uri, Source> uriToSource;
  final Set<Library> libSet;

  _Seed(this.libs, this.uriToSource) : libSet = {...libs};
}

class Driver {
  final List<(String, _Seed)> _seeds = [];
  String? _view;
  Process? _remover;
  final Map<String, String> _links = {};
  final Set<String> _dirs = {};

  /// Compiles one request. Returns null on success, else the diagnostics. A null [cacheKey]
  /// loads the seed for this compile only. Relative paths resolve against [base]; file system
  /// roots resolve inside [view] when given, else [base].
  Future<String?> compile(_Args a, {required String base, String? view, String? cacheKey}) async {
    final importPath = _join(base, a.imports.single);
    // Checked before any kernel read: the reader's own check fails with an opaque trace.
    final importHash = String.fromCharCodes(_sdkHash(importPath));
    if (_sdkHashDefine != importHash) {
      return "test_kernel_driver: -Dsdk_hash is '$_sdkHashDefine' but the import dill's SDK hash is "
          "'$importHash'; build the driver with -Dsdk_hash set to the SDK's Dart revision.";
    }
    final hint = a.errorHint == null || a.errorHint!.isEmpty ? '' : '\n${a.errorHint}';
    try {
      final sdkRoot = Uri.directory(_join(base, need(a.sdkRoot, '--sdk-root')));
      final packages = need(a.packages, '--packages');
      final output = _join(base, need(a.output, '--output-dill'));
      // dynamic: the target's API is the SDK's own, and its null-safe return type gets in the way.
      final dynamic target = createFrontEndTarget(
        'flutter',
        trackCreationLocations: a.trackWidgetCreation,
        supportMirrors: true,
        includeUnsupportedPlatformLibraryStubs: false,
        constKeepLocalsIndicator: true,
      );
      final seed = _seedFor(
        cacheKey == null ? null : '$cacheKey|${a.trackWidgetCreation}',
        () => _loadSeed(sdkRoot, importPath, target),
      );

      final errors = <String>[];
      final roots = [
        for (final r in a.roots) r == '.' ? (view ?? base) : _join(view ?? base, r),
      ];
      final options = CompilerOptions()
        ..sdkRoot = sdkRoot
        ..fileSystem = createFrontEndFileSystem('org-dartlang-root', roots)
        ..packagesFileUri = Uri.parse(packages)
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
        final source = resolveInputUri(_entryUri(a, base));
        // A fresh list per compile: the generator takes the list by reference.
        final gen = IncrementalKernelGenerator.fromComponent(
          options,
          [source],
          Component(
            libraries: List<Library>.of(seed.libs),
            uriToSource: Map<Uri, Source>.of(seed.uriToSource),
          ),
        );
        final res = await gen.computeDelta(entryPoints: [source]);
        if (errors.isNotEmpty) return errors.join('\n') + hint;
        final results = KernelCompilationResults.named(
          component: res.component,
          loadedLibraries: seed.libSet,
          classHierarchy: res.classHierarchy,
          coreTypes: res.coreTypes,
        );

        final full = '$work/kernel.dill';
        sortComponent(res.component);
        final sink = File(full).openWrite();
        BinaryPrinter(
          sink,
          libraryFilter: (lib) => !seed.libSet.contains(lib),
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
        return "test_kernel_driver: the output's SDK hash $got differs from the import dill's $want; "
            'the driver was built without the matching -Dsdk_hash';
      }
      return null;
    } on Object catch (err) {
      return '$err$hint';
    }
  }

  String _entryUri(_Args a, String base) {
    final path = need(a.entryPath, '--entry-path');
    if (need(a.entryScheme, '--entry-scheme') == 'package') {
      final name = File(_join(base, need(a.packageNameFile, '--package-name-file')))
          .readAsStringSync()
          .trimRight();
      return 'package:$name/$path';
    }
    return 'org-dartlang-root:///$path';
  }

  _Seed _seedFor(String? key, _Seed Function() load) {
    if (key == null) return load();
    final hit = _seeds.indexWhere((e) => e.$1 == key);
    if (hit >= 0) {
      final entry = _seeds.removeAt(hit);
      _seeds.add(entry);
      return entry.$2;
    }
    final seed = load();
    _seeds.add((key, seed));
    if (_seeds.length > _seedLimit) _seeds.removeAt(0);
    return seed;
  }

  _Seed _loadSeed(Uri sdkRoot, String importPath, dynamic target) {
    final root = CanonicalName.root();
    final platUri = sdkRoot.resolve('platform_strong.dill');
    final platform = _load(File.fromUri(platUri).readAsBytesSync(), root, '$platUri', target);
    final deps = _load(File(importPath).readAsBytesSync(), root, importPath, target);
    return _Seed(
      [...platform.libraries, ...deps.libraries],
      {...platform.uriToSource, ...deps.uriToSource},
    );
  }

  /// Makes the view hold exactly [inputs]: a link at each base-relative path, to `base/path`. A
  /// link that already points at the right target is kept, so a request with the same inputs as
  /// the last one does no filesystem work.
  Future<String> _mirrorView(String base, Iterable<String> inputs) async {
    final view = _view ??= await _startView();
    final want = {for (final rel in inputs) rel: _join(base, rel)};
    for (final rel in _links.keys.toList()) {
      if (want[rel] != _links[rel]) {
        Link('$view/$rel').deleteSync();
        _links.remove(rel);
      }
    }
    for (final entry in want.entries) {
      if (_links.containsKey(entry.key)) continue;
      final dst = '$view/${entry.key}';
      final dir = dst.substring(0, dst.lastIndexOf('/'));
      if (_dirs.add(dir)) Directory(dir).createSync(recursive: true);
      Link(dst).createSync(entry.value);
      _links[entry.key] = entry.value;
    }
    return view;
  }

  /// Serves one WorkRequest and returns its WorkResponse.
  Future<Map<String, Object?>> handle(Map<String, dynamic> req) async {
    final base = Directory((req['sandboxDir'] as String?) ?? Directory.current.path).absolute.path;
    Map<String, Object?> response(int exitCode, String output) => {
      'exitCode': exitCode,
      'output': output.isEmpty || output.endsWith('\n') ? output : '$output\n',
      if (req['requestId'] case final int id when id != 0) 'requestId': id,
    };

    try {
      final a = _Args.parse(_expand([for (final x in req['arguments'] as List) x as String], base));
      final inputs = {
        for (final item in req['inputs'] as List? ?? const [])
          (item as Map)['path'] as String: (item['digest'] ?? '') as String,
      };
      final importRel = a.imports.single;
      final digest = inputs[importRel];
      if (digest == null) {
        return response(1, 'test_kernel_driver: the import dill must be a declared input');
      }
      final view = await _mirrorView(base, inputs.keys);
      final error = await compile(
        a,
        base: base,
        view: view,
        cacheKey: '$importRel|$digest',
      );
      return error == null ? response(0, '') : response(1, error);
    } on Object catch (err) {
      return response(1, 'worker error: $err');
    }
  }

  /// Ends the remover, which removes the view.
  Future<void> close() async {
    final remover = _remover;
    if (remover == null) return;
    await remover.stdin.close();
    await remover.exitCode;
  }

  /// Creates the view, and a remover that deletes it once this process ends. The remover reads
  /// this process's stdin pipe, which stays open only while the process lives, so the view is
  /// removed even when Bazel kills the worker.
  Future<String> _startView() async {
    final view = Directory.systemTemp.createTempSync('test-kernel-view-$pid-').path;
    _remover = await Process.start('sh', ['-c', r'cat >/dev/null; rm -rf "$1"', 'sh', view]);
    return view;
  }
}

final _viewName = RegExp(r'^test-kernel-view-(\d+)-');

/// Removes views whose worker died without closing them, such as after SIGKILL.
void _removeDeadViews() {
  for (final entry in Directory.systemTemp.listSync()) {
    final owner = _viewName.firstMatch(entry.path.split('/').last)?.group(1);
    if (owner == null || Process.runSync('kill', ['-0', owner]).exitCode == 0) continue;
    try {
      entry.deleteSync(recursive: true);
    } on FileSystemException {
      // A worker starting at the same time may have removed it first.
    }
  }
}

Future<void> _serve() async {
  _removeDeadViews();
  final driver = Driver();
  await for (final line in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.trim().isEmpty) continue;
    final response = await driver.handle(jsonDecode(line) as Map<String, dynamic>);
    stdout.writeln(jsonEncode(response));
    await stdout.flush();
  }
  await driver.close();
}

Future<void> main(List<String> argv) async {
  if (argv.contains(_persistentFlag)) {
    await _serve();
    return;
  }
  final cwd = Directory.current.path;
  try {
    final a = _Args.parse(_expand(argv, cwd));
    final error = await Driver().compile(a, base: cwd);
    if (error != null) {
      stderr.writeln(error);
      exitCode = 1;
    }
  } on Object catch (err) {
    stderr.writeln('test_kernel_driver: $err');
    exitCode = 1;
  }
}
