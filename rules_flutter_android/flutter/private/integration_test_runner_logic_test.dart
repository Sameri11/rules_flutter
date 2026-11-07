import 'dart:convert';

import '{{LOGIC_IMPORT}}';
import '{{FRAME_IMPORT}}' as frame;

const _logcat = 'I/flutter ( 4242): ';

Future<void> main() async {
  _footer();
  _devices();
  _versions();
  _runningCase();
  _deadline();
  await _footerAfterExit();
}

void _footer() {
  _expect(hasFooter('RFT_END|abc|0', 'abc'), 'footer of the run');
  _expect(!hasFooter('RFT|abc|0|0/1|x', 'abc'), 'frame is not a footer');
  _expect(!hasFooter('RFT_END|foreign|0', 'abc'), 'foreign footer');
  _expect(hasRunFrame('${_logcat}RFT|abc|0|0/1|x', 'abc'), 'run frame in a logcat line');
  _expect(!hasRunFrame('${_logcat}RFT|foreign|0|0/1|x', 'abc'), 'foreign run frame');
}

void _devices() {
  const header = 'List of devices attached\n';
  final one = parseDevices('${header}emulator-5554\tdevice\n');
  _same(selectDevice(one, null), 'emulator-5554', 'sole device');
  _same(selectDevice(one, ''), 'emulator-5554', 'empty ANDROID_SERIAL');
  _throws(() => selectDevice(one, 'unknown'), 'ANDROID_SERIAL unknown is not an available device');
  _throws(() => selectDevice([], null), 'found 0');
  final two = parseDevices('${header}emulator-5554\tdevice\nemulator-5556\tdevice\n');
  _throws(() => selectDevice(two, null), 'found 2. Set ANDROID_SERIAL');
  _same(selectDevice(two, 'emulator-5556'), 'emulator-5556', 'explicit serial of two');
  final mixed = parseDevices('${header}phone\toffline\nemulator-5554\tdevice\n');
  _same(selectDevice(mixed, 'emulator-5554'), 'emulator-5554', 'offline device elsewhere');
  _throws(() => selectDevice(mixed, 'phone'), 'Android device phone is offline');
  _throws(
    () => selectDevice(parseDevices('${header}phone\tunauthorized\n'), null),
    'Android device phone is unauthorized',
  );
}

void _versions() {
  _throws(() => compareVersions(41, 42), 'server 41, client 42');
  _throws(() => compareVersions(41, 42), 'start the server with the declared SDK adb');
  _same(compareVersions(42, 42), 42, 'matching versions');
}

String _event(String run, int seq, Map<String, Object?> payload) => frame
    .encodeEvent(run, seq, frame.escapePayload(jsonEncode({'run': run, 'seq': seq, ...payload})))
    .map((line) => '$_logcat$line\n')
    .join();

void _runningCase() {
  String? running(String text) => runningCase(text, 'abc', frame.unescapePayload);
  final name = 'renders "quoted" \\ back\\slashes, café and ${'a long name ' * 60}';
  final long = _event('abc', 0, {'type': 'running', 'name': name});
  _expect('\n'.allMatches(long).length > 1, 'long name splits across frames');
  _same(running(long), name, 'name across chunks');
  _same(running('${long}garbage\n${_event('foreign', 1, {'type': 'running', 'name': 'other'})}'), name,
      'noise and foreign runs');
  final next = _event('abc', 1, {'type': 'running', 'name': 'second'});
  _same(running('$long$next'), 'second', 'latest running event');
  final between = _event('abc', 1, {'type': 'running', 'name': null});
  _same(running('$long$between'), null, 'between cases');
  final cut = long.split('\n').where((line) => !line.contains('|1/')).join('\n');
  _same(running('$cut$next'), 'second', 'event with a lost chunk is skipped');
  _same(running(cut), null, 'only an incomplete event');
}

void _deadline() {
  _same(runnerDeadline(const Duration(seconds: 60)), const Duration(seconds: 45), '60 s timeout');
  _same(runnerDeadline(const Duration(seconds: 300)), const Duration(seconds: 270), '300 s timeout');
  _same(runnerDeadline(const Duration(seconds: 10)), const Duration(seconds: 5), '10 s timeout');
  _same(runnerDeadline(const Duration(seconds: 4)), const Duration(seconds: 2), '4 s timeout');
}

Future<void> _footerAfterExit() async {
  final stream = StringBuffer('RFT|abc|0|0/1|x\n');
  Future<void>.delayed(const Duration(milliseconds: 300), () => stream.write('RFT_END|abc|0\n'));
  _expect(
    await awaitFooter(stream.toString, 'abc', const Duration(seconds: 2)),
    'footer arriving after the process exit is a finished run',
  );
  _expect(
    !await awaitFooter(() => 'RFT|abc|0|0/1|x\n', 'abc', const Duration(milliseconds: 300)),
    'no footer within the grace period is a crash',
  );
}

void _expect(bool condition, String what) {
  if (!condition) throw StateError('Expectation failed: $what');
}

void _same(Object? actual, Object? expected, String what) {
  if (actual != expected) throw StateError('$what: expected $expected, got $actual');
}

void _throws(void Function() action, String expected) {
  try {
    action();
  } on FormatException catch (error) {
    if (!error.message.contains(expected)) {
      throw StateError('Expected "$expected" in "${error.message}".');
    }
    return;
  }
  throw StateError('Expected FormatException containing "$expected"');
}
