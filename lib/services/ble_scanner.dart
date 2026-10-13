import 'dart:async';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// One received Bluetooth advertisement, reduced to what the radar needs.
class RawAdvert {
  const RawAdvert(this.serviceUuids, this.rssi);
  final List<String> serviceUuids;
  final int rssi;
}

enum ScanStartResult { ok, permissionDenied, bluetoothOff, unsupported, error }

/// What the radar needs from the phone's Bluetooth radio (a seam so the logic is testable without hardware).
abstract class BleScanner {
  Stream<RawAdvert> get adverts;

  /// true while the phone's Bluetooth adapter is on.
  Stream<bool> get bluetoothOn;

  Future<ScanStartResult> start();
  Future<void> stop();

  /// Android only: asks the user to switch Bluetooth on.
  Future<bool> turnOn();
}

class PlusScanner implements BleScanner {
  final StreamController<RawAdvert> _out = StreamController<RawAdvert>.broadcast();
  StreamSubscription<List<ScanResult>>? _sub;

  @override
  Stream<RawAdvert> get adverts => _out.stream;

  @override
  Stream<bool> get bluetoothOn => FlutterBluePlus.adapterState.map((s) => s == BluetoothAdapterState.on);

  @override
  Future<ScanStartResult> start() async {
    try {
      if (!await FlutterBluePlus.isSupported) return ScanStartResult.unsupported;

      final state = await FlutterBluePlus.adapterState.first;
      if (state == BluetoothAdapterState.unauthorized) return ScanStartResult.permissionDenied;
      if (state != BluetoothAdapterState.on) return ScanStartResult.bluetoothOff;

      await _sub?.cancel();
      _sub = FlutterBluePlus.onScanResults.listen((results) {
        for (final r in results) {
          _out.add(RawAdvert(
            r.advertisementData.serviceUuids.map((g) => g.str128).toList(),
            r.rssi,
          ));
        }
      });

      // One long scan (Android allows only 5 scan starts per 30 s). Every advertisement is reported,
      // including repeats, because a student's code (and RSSI) changes while they are in range.
      await FlutterBluePlus.startScan(
        timeout: const Duration(minutes: 30),
        continuousUpdates: true,
        oneByOne: true,
        androidLegacy: true,
        androidScanMode: AndroidScanMode.lowLatency,
      );
      return ScanStartResult.ok;
    } catch (e) {
      final text = e.toString().toLowerCase();
      if (text.contains('permission') || text.contains('unauthorized') || text.contains('denied')) {
        return ScanStartResult.permissionDenied;
      }
      if (text.contains('adapter') || text.contains('turned off') || text.contains('powered off') || text.contains('is off')) {
        return ScanStartResult.bluetoothOff;
      }
      return ScanStartResult.error;
    }
  }

  @override
  Future<void> stop() async {
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
    await _sub?.cancel();
    _sub = null;
  }

  @override
  Future<bool> turnOn() async {
    try {
      await FlutterBluePlus.turnOn();
      return true;
    } catch (_) {
      return false;
    }
  }
}
