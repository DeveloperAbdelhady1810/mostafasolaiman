import 'package:flutter_ble_peripheral/flutter_ble_peripheral.dart';

/// Puts one short Bluetooth advertisement on air. A seam so the reply queue is testable without hardware.
abstract class ReplyAdvertiser {
  /// false when this phone cannot advertise or the permission was refused (replies are then skipped;
  /// the radar and the server confirmation still work).
  Future<bool> prepare();
  Future<bool> start(String serviceUuid);
  Future<void> stop();
}

class PluginReplyAdvertiser implements ReplyAdvertiser {
  final FlutterBlePeripheral _p = FlutterBlePeripheral();

  @override
  Future<bool> prepare() async {
    try {
      if (!await _p.isSupported) return false;
      if (await _p.hasPermission() == PeripheralBluetoothState.granted) return true;
      return await _p.requestPermission() == PeripheralBluetoothState.granted;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> start(String serviceUuid) async {
    try {
      final state = await _p.start(
        advertiseData: AdvertiseDataCore(serviceUuid: serviceUuid),
        androidSettings: const AndroidAdvertiseSettings(
          advertiseSettings: AdvertiseSettings(
            connectable: false,
            timeout: 0,
            advertiseMode: AdvertiseMode.advertiseModeLowLatency,
            txPowerLevel: AdvertiseTxPower.advertiseTxPowerHigh,
          ),
        ),
      );
      return state == PeripheralBluetoothState.ready || state == PeripheralBluetoothState.granted;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _p.stop();
    } catch (_) {}
  }
}
