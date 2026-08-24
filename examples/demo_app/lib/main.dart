import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:rive_common/rive_text.dart';
import 'package:rive_native/rive_native.dart' as rive_native;
import 'package:sqlite3/sqlite3.dart';
import 'package:mylib/mylib.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter Demo',
      theme: ThemeData(
        // This is the theme of your application.
        //
        // TRY THIS: Try running your application with "flutter run". You'll see
        // the application has a purple toolbar. Then, without quitting the app,
        // try changing the seedColor in the colorScheme below to Colors.green
        // and then invoke "hot reload" (save your changes or press the "hot
        // reload" button in a Flutter-supported IDE, or press "r" if you used
        // the command line to start the app).
        //
        // Notice that the counter didn't reset back to zero; the application
        // state is not lost during the reload. To reset the state, use hot
        // restart instead.
        //
        // This works for code too, not just values: Most code changes can be
        // tested with just a hot reload.
        colorScheme: .fromSeed(seedColor: Colors.deepPurple),
      ),
      home: MyHomePage(title: greeting()),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  // This widget is the home page of your application. It is stateful, meaning
  // that it has a State object (defined below) that contains fields that affect
  // how it looks.

  // This class is the configuration for the state. It holds the values (in this
  // case the title) provided by the parent (in this case the App widget) and
  // used by the build method of the State. Fields in a Widget subclass are
  // always marked "final".

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  int _counter = 0;

  // Exercises the connectivity_plus plugin. This is the platform-channel
  // equivalent of the mylib string in the app bar: a result here means the
  // whole plugin chain ran -- the registrant instantiated ConnectivityPlugin,
  // the plugin's Java reached the platform, and the reply came back to Dart.
  // Registration failures are logged rather than thrown, so a plugin that never
  // loaded leaves this at 'pending' instead of crashing.
  String _connectivity = 'pending';

  // image_picker is the harder plugin: res/, a manifest provider, and AndroidX
  // dependencies that had to be resolved rather than assumed. retrieveLostData
  // is used because it is Android-only and needs no UI -- reaching the platform
  // and returning "no lost data" is the whole assertion.
  String _picker = 'pending';

  // rive_common is the native case: its Android half compiles ~1400 C/C++
  // sources through CMake into librive_text.so. Font.initialize() is the whole
  // chain in one call -- the plugin's Kotlin does System.loadLibrary("rive_text"),
  // then Dart calls into the library over FFI. A .so that is missing from the
  // APK, built for the wrong architecture, or aligned for 4 KB pages fails
  // here; none of those are visible from a successful build.
  String _rive = 'pending';

  // sqlite3 is the *native assets* case, and the only check here that does not
  // go through a Flutter plugin at all -- it has no android/ module, so the
  // plugin machinery never sees it. Its libsqlite3.so comes from a Dart build
  // hook, and the VM finds it by asset id
  // (`package:sqlite3/src/ffi/libsqlite3.g.dart`) rather than by library name.
  //
  // `sqlite3.version` is an FFI call through @Native/addressOf, so it exercises
  // three independent things at once, none of which a successful build shows:
  // the .so reached lib/<abi>/ in the APK, the asset mapping was compiled into
  // the kernel, and the mapping points at the right filename.
  String _sqlite = 'pending';

  // rive_native is the counterpart to rive_common: an ordinary Kotlin Android
  // module whose native half is never compiled -- a Gradle Exec task downloads
  // it. RiveNative.init() returns false rather than throwing when the library
  // is absent, so the result is reported either way instead of being swallowed.
  String _riveNative = 'pending';

  @override
  void initState() {
    super.initState();
    _checkConnectivity();
    _checkPicker();
    _checkRive();
    _checkSqlite();
    _checkRiveNative();
  }

  Future<void> _checkRiveNative() async {
    late final String result;
    try {
      result = await rive_native.RiveNative.init() ? 'success' : 'failed: init returned false';
    } catch (e) {
      result = 'failed: $e';
    }
    debugPrint('rive_native: $result');
    if (mounted) {
      setState(() => _riveNative = result);
    }
  }

  Future<void> _checkSqlite() async {
    late final String result;
    try {
      result = sqlite3.version.toString();
    } catch (e) {
      result = 'failed: $e';
    }
    debugPrint('sqlite3: $result');
    if (mounted) {
      setState(() => _sqlite = result);
    }
  }

  Future<void> _checkRive() async {
    late final String result;
    try {
      final status = await Font.initialize();
      result = status.name;
    } catch (e) {
      result = 'failed: $e';
    }
    debugPrint('rive_common: $result');
    if (mounted) {
      setState(() => _rive = result);
    }
  }

  Future<void> _checkPicker() async {
    late final String result;
    try {
      final lost = await ImagePicker().retrieveLostData();
      result = lost.isEmpty ? 'ok (no lost data)' : 'ok (${lost.type})';
    } catch (e) {
      result = 'failed: $e';
    }
    debugPrint('image_picker: $result');
    if (mounted) {
      setState(() => _picker = result);
    }
  }

  Future<void> _checkConnectivity() async {
    late final String result;
    try {
      final value = await Connectivity().checkConnectivity();
      result = value.map((r) => r.name).join(', ');
    } catch (e) {
      result = 'failed: $e';
    }
    debugPrint('connectivity_plus: $result');
    if (mounted) {
      setState(() => _connectivity = result);
    }
  }

  void _incrementCounter() {
    setState(() {
      // This call to setState tells the Flutter framework that something has
      // changed in this State, which causes it to rerun the build method below
      // so that the display can reflect the updated values. If we changed
      // _counter without calling setState(), then the build method would not be
      // called again, and so nothing would appear to happen.
      _counter++;
    });
  }

  @override
  Widget build(BuildContext context) {
    // This method is rerun every time setState is called, for instance as done
    // by the _incrementCounter method above.
    //
    // The Flutter framework has been optimized to make rerunning build methods
    // fast, so that you can just rebuild anything that needs updating rather
    // than having to individually change instances of widgets.
    return Scaffold(
      appBar: AppBar(
        // TRY THIS: Try changing the color here to a specific color (to
        // Colors.amber, perhaps?) and trigger a hot reload to see the AppBar
        // change color while the other colors stay the same.
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        // Here we take the value from the MyHomePage object that was created by
        // the App.build method, and use it to set our appbar title.
        title: Text(widget.title),
      ),
      body: Center(
        // Center is a layout widget. It takes a single child and positions it
        // in the middle of the parent.
        child: Column(
          // Column is also a layout widget. It takes a list of children and
          // arranges them vertically. By default, it sizes itself to fit its
          // children horizontally, and tries to be as tall as its parent.
          //
          // Column has various properties to control how it sizes itself and
          // how it positions its children. Here we use mainAxisAlignment to
          // center the children vertically; the main axis here is the vertical
          // axis because Columns are vertical (the cross axis would be
          // horizontal).
          //
          // TRY THIS: Invoke "debug painting" (choose the "Toggle Debug Paint"
          // action in the IDE, or press "p" in the console), to see the
          // wireframe for each widget.
          mainAxisAlignment: .center,
          children: [
            const Text('You have pushed the button this many times:'),
            Text(
              '$_counter',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            Text('connectivity: $_connectivity'),
            Text('image_picker: $_picker'),
            Text('rive_common: $_rive'),
            Text('sqlite3: $_sqlite'),
            Text('rive_native: $_riveNative'),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _incrementCounter,
        tooltip: 'Increment',
        child: const Icon(Icons.add),
      ),
    );
  }
}
