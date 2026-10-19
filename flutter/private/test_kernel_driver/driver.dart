// Test-kernel driver for dart_test_kernel: a Bazel persistent worker that is also the batch
// command.
//
// Bazel runs `dart driver.dill --idle-exit-seconds=<n> [--persistent_worker]`. The request
// arguments are the frontend command on the command line (an @params file, one-shot) or in a
// WorkRequest (worker).
//
// One-shot (no --persistent_worker): the batch command. frontend_server runs with the rule's
// flags, then its per-package pieces are joined into the output.
// Bazel uses this under --strategy=DartTestKernel=sandboxed.
//
// Worker: one JSON WorkRequest per line on stdin, one WorkResponse per line on stdout. Under
// multiplex, requests arrive concurrently; each is answered when done. Each request sees a view, a
// directory of symlinks to exactly its declared inputs, and its file-system roots are that view and
// the bin directory, so the compile cannot read anything Bazel did not declare for it. The view is
// one directory per process, mirrored to each request by diff (see _mirrorView): a request costs
// only the links that differ from the last one. Paths are relative to the request's sandboxDir when
// it has one, else to the execroot.
//
// Compiles are serialized in the process. They share one seed: platform_strong.dill plus the
// import dills, concatenated in order, loaded once and kept while the (imports, digests, package
// config) key is unchanged.
// A compile runs IncrementalKernelGenerator.fromComponent over a fresh copy of the seed's
// libraries, then writes the output the way the batch path does: sortComponent, BinaryPrinter
// filtered to the non-seed libraries, writeOutputSplitByPackages, and the same join (main piece
// first).
//
// The process exits after --idle-exit-seconds with no request in flight, or when stdin closes.
//
// Built into the `test_kernel_driver` repository by frontend_server with -Dsdk_hash=<pin>.
import 'dart:async';
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

const _persistentFlag = '--persistent_worker';
const _idleFlag = '--idle-exit-seconds=';
const _noDependencyList = '--no-print-incremental-dependencies';
const _sdkHashOffset = 8;
const _sdkHashLength = 10;

// Consumed by the driver; never passed to the frontend.
const _driverValues = {
  '--dartaotruntime',
  '--frontend-server',
  '--package-name-file',
  '--entry-scheme',
  '--entry-path',
  '--output-dill',
  '--error-hint',
};

// Read by the driver and also passed to the frontend (the batch command).
const _frontendValues = {'--sdk-root', '--packages', '--filesystem-root'};

// Repeatable. The driver concatenates the imports in order; the frontend reads the one result.
const _importDill = '--import-dill';

String _join(String base, String path) => path.startsWith('/') ? path : '$base/$path';

/// The import dills' bytes, concatenated in order.
Uint8List _concat(List<String> imports, String base) {
  final out = BytesBuilder(copy: false);
  for (final rel in imports) {
    out.add(File(_join(base, rel)).readAsBytesSync());
  }
  return out.takeBytes();
}

/// `@file` arguments expand to their lines, relative to [base] (one argument per line).
List<String> _expand(List<String> args, String base) {
  final out = <String>[];
  for (final a in args) {
    if (a.startsWith('@') && !a.startsWith('@@')) {
      final file = File(_join(base, a.substring(1)));
      if (file.existsSync()) {
        out.addAll(file.readAsLinesSync());
        continue;
      }
    }
    out.add(a);
  }
  return out;
}

/// One request's frontend command, split into the driver's values and the frontend's arguments.
class Request {
  final Map<String, String> values = {};
  final List<String> roots = [];
  final List<String> imports = [];
  final List<String> frontend = [];

  Request.parse(List<String> args) {
    for (var i = 0; i < args.length; i++) {
      final a = args[i];
      if (_driverValues.contains(a)) {
        values[a] = args[++i];
      } else if (a == _noDependencyList) {
        // Batch-only detail the frontend need not see; the driver never prints dependencies.
      } else if (a == _importDill) {
        imports.add(args[++i]);
      } else if (_frontendValues.contains(a)) {
        final v = args[++i];
        values[a] = v;
        if (a == '--filesystem-root') roots.add(v);
        frontend..add(a)..add(v);
      } else {
        frontend.add(a);
      }
    }
  }

  String get(String flag) {
    final v = values[flag];
    if (v == null) throw FormatException('test_kernel_driver: expected $flag');
    return v;
  }
}

/// Phase timings in ms for the request being compiled; printed with the success line.
final Map<String, int> _ms = {};
/// Seed loads since this process started.
int _seedLoads = 0;

/// The view, kept across requests (see [_mirrorView]); created on the first request.
String? _viewDir;
/// The links in the view: view-relative path to link target.
final Map<String, String> _viewLinks = {};
/// The directories already created in the view.
final Set<String> _viewDirs = {};

/// Makes the view hold exactly the request's declared inputs: a link at each base-relative path, to
/// `base/rel`, and no other link. A link that already points at the right target is kept, so a request
/// with the same inputs as the last one does no filesystem work. Compiles run one at a time ([Serial]),
/// so the view is never mirrored while another request reads it. Returns the view's path.
String _mirrorView(String base, Iterable<String> inputs) {
  final view = _viewDir ??= Directory.systemTemp.createTempSync('kview-').path;
  final want = {for (final rel in inputs) rel: _join(base, rel)};
  for (final rel in _viewLinks.keys.toList()) {
    if (want[rel] != _viewLinks[rel]) {
      Link('$view/$rel').deleteSync();
      _viewLinks.remove(rel);
    }
  }
  for (final entry in want.entries) {
    if (_viewLinks.containsKey(entry.key)) continue;
    final dst = '$view/${entry.key}';
    final dir = dst.substring(0, dst.lastIndexOf('/'));
    if (_viewDirs.add(dir)) Directory(dir).createSync(recursive: true);
    Link(dst).createSync(entry.value);
    _viewLinks[entry.key] = entry.value;
  }
  return view;
}

/// Runs [fn] after every earlier call has finished. A failed call does not block the next.
class Serial {
  Future<void> _tail = Future.value();

  Future<T> run<T>(Future<T> Function() fn) {
    final next = _tail.then((_) => fn());
    _tail = next.then((_) {}, onError: (_) {});
    return next;
  }
}

/// The one-shot batch command: frontend_server, then the join of its per-package pieces.
Future<int> batch(Request r, String base) async {
  final dill = _join(base, r.get('--output-dill'));
  final entry = _entryUri(r, base);
  final work = Directory.systemTemp.createTempSync('kbatch-');
  try {
    final kernel = '${work.path}/kernel.dill';
    // One import dill for the frontend: the file itself, or the imports concatenated in a scratch file.
    final imports = <String>[];
    if (r.imports.length == 1) {
      imports.addAll([_importDill, _join(base, r.imports.single)]);
    } else if (r.imports.length > 1) {
      final joined = '${work.path}/import.dill';
      File(joined).writeAsBytesSync(_concat(r.imports, base));
      imports.addAll([_importDill, joined]);
    }
    final cmd = [
      _join(base, r.get('--dartaotruntime')),
      _join(base, r.get('--frontend-server')),
      ...r.frontend,
      ...imports,
      '--output-dill',
      kernel,
      entry,
    ];
    final proc = await Process.start(cmd.first, cmd.sublist(1), mode: ProcessStartMode.inheritStdio);
    final rc = await proc.exitCode;
    if (rc != 0) {
      final hint = r.values['--error-hint'];
      if (hint != null && hint.isNotEmpty) stderr.writeln(hint);
      return rc;
    }
    final out = File(dill).openWrite();
    final packages = File('$kernel-packages');
    if (packages.existsSync()) {
      out.add(File('$kernel-main.dilp').readAsBytesSync());
      for (final pkg in packages.readAsLinesSync()) {
        if (pkg != 'main' && pkg.isNotEmpty) {
          out.add(File('$kernel-$pkg.dilp').readAsBytesSync());
        }
      }
    } else {
      out.add(File(kernel).readAsBytesSync());
    }
    await out.close();
    return 0;
  } finally {
    work.deleteSync(recursive: true);
  }
}

String _entryUri(Request r, String base) {
  final scheme = r.get('--entry-scheme');
  final path = r.get('--entry-path');
  if (scheme == 'package') {
    final name = File(_join(base, r.get('--package-name-file'))).readAsStringSync().trimRight();
    return 'package:$name/$path';
  }
  return 'org-dartlang-root:///$path';
}

class Seed {
  final List<Library> libs;
  final Map<Uri, Source> uriToSource;
  final Set<Library> libSet;
  Seed(this.libs, this.uriToSource) : libSet = {...libs};
}

Component _load(Uint8List bytes, CanonicalName root, String filename, dynamic target) {
  final c = target.configureComponent(Component(nameRoot: root)) as Component;
  BinaryBuilder(bytes, filename: filename, disableLazyReading: false).readComponent(c);
  return c;
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

/// The result of one request: a WorkResponse's exitCode and output.
class Outcome {
  final int exitCode;
  final String output;
  const Outcome(this.exitCode, this.output);
  Outcome.failure(String output) : this(1, output);
}

class Driver {
  final dynamic target = createFrontEndTarget(
    'flutter',
    trackCreationLocations: true,
    supportMirrors: true,
    includeUnsupportedPlatformLibraryStubs: false,
    constKeepLocalsIndicator: true,
  );
  final Serial _queue = Serial();
  String? _seedKey;
  Seed? _seed;

  Future<Outcome> compile(Map<String, dynamic> req) => _queue.run(() => _compile(req));

  Seed _loadSeed(Uri sdkRoot, List<String> imports, String base) {
    final root = CanonicalName.root();
    final platUri = sdkRoot.resolve('platform_strong.dill');
    final plat = _load(File.fromUri(platUri).readAsBytesSync(), root, '$platUri', target);
    final deps = _load(_concat(imports, base), root, imports.join(', '), target);
    return Seed(
      [...plat.libraries, ...deps.libraries],
      {...plat.uriToSource, ...deps.uriToSource},
    );
  }

  // Undeclared hardening probes visible from the working directory; the hardening check reads this.
  int _hardeningProbes() => Directory.current
      .listSync()
      .where((e) => e.path.split('/').last.startsWith('hardening-probe-'))
      .length;

  Future<Outcome> _compile(Map<String, dynamic> req) async {
    final sw = Stopwatch()..start();
    _ms.clear();
    // A sandboxDir may be relative to the worker's working directory; symlink targets need it absolute.
    final base = Directory((req['sandboxDir'] as String?) ?? Directory.current.path).absolute.path;
    final args = [for (final a in req['arguments'] as List) a as String];
    final r = Request.parse(_expand(args, base));
    final hint = r.values['--error-hint'];
    String failure(String text) =>
        text + (hint == null || hint.isEmpty ? '' : '\n$hint');

    final inputs = <String, String>{
      for (final item in (req['inputs'] as List? ?? const []))
        (item as Map)['path'] as String: (item['digest'] ?? '') as String,
    };
    final importRels = r.imports;
    if (importRels.isEmpty || importRels.any((rel) => !inputs.containsKey(rel))) {
      return Outcome.failure(failure('test_kernel_driver: the import dills must be declared inputs'));
    }

    try {
      final tView = Stopwatch()..start();
      final viewPath = _mirrorView(base, inputs.keys);
      _ms['view'] = tView.elapsedMilliseconds;
      final roots = [
        viewPath,
        for (final root in r.roots)
          if (root != '.') _join(base, root),
      ];
      final packages = r.get('--packages');
      final sdkRoot = Uri.directory(_join(base, r.get('--sdk-root')));
      final key = '${[for (final rel in importRels) '$rel|${inputs[rel]}'].join(',')}|$packages';
      if (_seedKey != key) {
        _seed = null; // eviction: the old seed is freed here
        _seedKey = key;
        final tSeed = Stopwatch()..start();
        _seed = _loadSeed(sdkRoot, importRels, base);
        _ms['seed'] = tSeed.elapsedMilliseconds;
        _seedLoads++;
      }
      final dest = _join(base, r.get('--output-dill'));
      Directory(File(dest).parent.path).createSync(recursive: true);
      final tRun = Stopwatch()..start();
      final errors = await _run(
        _seed!,
        sdkRoot,
        packages,
        roots,
        resolveInputUri(_entryUri(r, base)),
        dest,
      );
      _ms['run'] = tRun.elapsedMilliseconds;
      if (errors != null) return Outcome.failure(failure(errors));

      final tHash = Stopwatch()..start();
      final outHash = _sdkHash(dest);
      final inHash = _sdkHash(_join(base, importRels.first));
      _ms['hash'] = tHash.elapsedMilliseconds;
      if (_hex(outHash) != _hex(inHash)) {
        return Outcome.failure(failure(
          "test_kernel_driver: the output's SDK hash ${_hex(outHash)} differs from the import dill's "
          "${_hex(inHash)}; the driver was built without the matching -Dsdk_hash",
        ));
      }
      stderr.writeln(
        'test_kernel_driver: ${r.get('--output-dill')}: ${sw.elapsedMilliseconds} ms, ${inputs.length} inputs, '
        'sandboxed=${req['sandboxDir'] != null}, cwd=${Directory.current.path}, probes=${_hardeningProbes()}, '
        'phases=$_ms, seedLoads=$_seedLoads',
      );
      return const Outcome(0, '');
    } on Object catch (err) {
      return Outcome.failure(failure('$err'));
    }
  }

  /// Compiles one request into [dest]. Returns null on success, else the diagnostics.
  Future<String?> _run(
    Seed seed,
    Uri sdkRoot,
    String packages,
    List<String> roots,
    Uri source,
    String dest,
  ) async {
    final errors = <String>[];
    final options = CompilerOptions()
      ..sdkRoot = sdkRoot
      ..fileSystem = createFrontEndFileSystem('org-dartlang-root', roots)
      ..packagesFileUri = Uri.parse(packages)
      ..sdkSummary = sdkRoot.resolve('platform_strong.dill')
      ..embedSourceText = false
      ..target = target
      ..onDiagnostic = (CfeDiagnosticMessage m) {
        switch (m.severity) {
          case CfeSeverity.error:
          case CfeSeverity.internalProblem:
            errors.addAll(m.plainTextFormatted);
          default:
            break;
        }
      }
      ..environmentDefines = target.updateEnvironmentDefines({
        'dart.vm.profile': 'false',
        'dart.vm.product': 'false',
      });

    final work = '$dest.work';
    try {
      Directory(work).createSync(recursive: true);
      // A fresh list per request: the generator takes the list by reference.
      final seedComponent = Component(
        libraries: List<Library>.of(seed.libs),
        uriToSource: Map<Uri, Source>.of(seed.uriToSource),
      );
      final tGen = Stopwatch()..start();
      final gen = IncrementalKernelGenerator.fromComponent(options, [source], seedComponent);
      final res = await gen.computeDelta(entryPoints: [source]);
      _ms['gen'] = tGen.elapsedMilliseconds;
      if (errors.isNotEmpty) return errors.join('\n');
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

      final join = File(dest).openWrite();
      join.add(File('$full-main.dilp').readAsBytesSync());
      for (final pkg in File('$full-packages').readAsLinesSync()) {
        if (pkg != 'main' && pkg.isNotEmpty) {
          join.add(File('$full-$pkg.dilp').readAsBytesSync());
        }
      }
      await join.close();
      return null;
    } on Object catch (e) {
      return [...errors, '$e'].join('\n');
    } finally {
      final dir = Directory(work);
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
  }
}

/// Removes the view, then exits. A kill (SIGKILL) leaves the view behind; it holds links only.
void _exitDriver() {
  final dir = _viewDir;
  if (dir != null) Directory(dir).deleteSync(recursive: true);
  exit(0);
}

Future<void> serve(Duration idle) async {
  final driver = Driver();
  var inFlight = 0;
  Timer? timer;
  final pending = <Future<void>>[];

  void arm() {
    if (idle > Duration.zero && inFlight == 0) {
      timer = Timer(idle, _exitDriver);
    }
  }

  final lines = stdin.transform(utf8.decoder).transform(const LineSplitter());
  await for (final line in lines) {
    if (line.trim().isEmpty) continue;
    final req = jsonDecode(line) as Map<String, dynamic>;
    if (req['cancel'] == true) continue;
    inFlight++;
    timer?.cancel();
    timer = null;
    pending.add(() async {
      Outcome outcome;
      try {
        outcome = await driver.compile(req);
      } on Object catch (err) {
        outcome = Outcome.failure('worker error: $err');
      }
      final resp = <String, Object?>{'exitCode': outcome.exitCode, 'output': outcome.output};
      final id = req['requestId'];
      if (id != null && id != 0) resp['requestId'] = id;
      stdout.writeln(jsonEncode(resp));
      await stdout.flush();
      inFlight--;
      if (inFlight == 0) arm();
    }());
  }
  await Future.wait(pending);
  _exitDriver();
}

Future<void> main(List<String> argv) async {
  var idleSeconds = 0;
  var persistent = false;
  final args = <String>[];
  for (final a in argv) {
    if (a == _persistentFlag) {
      persistent = true;
    } else if (a.startsWith(_idleFlag)) {
      idleSeconds = int.parse(a.substring(_idleFlag.length));
    } else {
      args.add(a);
    }
  }
  if (persistent) {
    await serve(Duration(seconds: idleSeconds));
    return;
  }
  final cwd = Directory.current.path;
  try {
    exit(await batch(Request.parse(_expand(args, cwd)), cwd));
  } on Object catch (err) {
    stderr.writeln('test_kernel_driver: $err');
    exit(1);
  }
}
