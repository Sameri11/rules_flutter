import 'integration_test_runner_logic.dart';

void main() {
  _expect(hasFooter('RFT_END|abc|0', 'abc'));
  _expect(!hasFooter('RFT|abc|event', 'abc'));
  _expect(!hasFooter('RFT_END|foreign|0', 'abc'));

  final devices = parseDevices('List of devices attached\nemulator-5554 device product:x\n');
  _expect(selectDevice(devices, null) == 'emulator-5554');
  _throws(() => selectDevice(devices, 'unknown'), 'unknown');
  _throws(() => selectDevice([], null), 'found 0');
  _throws(() => selectDevice(['one', 'two'], null), 'found 2');
  _throws(() => parseDevices('List of devices attached\nphone unauthorized usb:x\n'), 'unauthorized');
  _throws(() => parseDevices('List of devices attached\nphone offline usb:x\n'), 'offline');
  _throws(() => compareVersions(42, 43), 'start the server with the declared SDK adb');
  _expect(compareVersions(42, 42) == 42);
}

void _expect(bool condition) {
  if (!condition) throw StateError('Runner logic expectation failed');
}
void _throws(void Function() action, String expected) {
  try {
    action();
  } on FormatException catch (error) {
    assert(error.message.toString().contains(expected));
    return;
  }
  throw StateError('Expected FormatException containing $expected');
}
