import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/scan.dart';
import '../services/ble_scanner.dart';
import '../services/radar_book.dart';
import '../services/reply_queue.dart';

enum RadarStatus { idle, starting, scanning, needsPermission, bluetoothOff, unsupported, error }

/// Drives the Classroom Radar: listens to Bluetooth advertisements, keeps one entry per student,
/// applies the signal-strength threshold and lets the assistant untick anyone detected by mistake
/// (e.g. through a wall) before confirming.
class RadarProvider extends ChangeNotifier {
  RadarProvider({
    required BleScanner scanner,
    required int Function() serverNow,
    this.threshold = -75,
    RadarBook? book,
    this.replies,
  })  : _scanner = scanner,
        _serverNow = serverNow,
        book = book ?? RadarBook();

  final BleScanner _scanner;
  final int Function() _serverNow;
  final RadarBook book;

  /// Answers each student in range with a Bluetooth "I heard you" (null = no replies).
  final ReplyQueue? replies;

  /// Students whose signal is weaker than this (dBm) are ignored. Higher (closer to 0) = must be nearer.
  int threshold;

  RadarStatus status = RadarStatus.idle;

  /// Students the assistant unticked: they stay listed but are not sent on Confirm.
  final Set<int> excluded = {};

  /// A student came into range for the first time (play the tick).
  void Function(Detection)? onNewDetection;

  StreamSubscription<RawAdvert>? _advertSub;
  StreamSubscription<bool>? _stateSub;
  bool _disposed = false;

  bool get isScanning => status == RadarStatus.scanning;

  List<Detection> get pending => book.pending(threshold);
  List<Detection> get confirmed => book.confirmedList();
  List<Detection> get selected => pending.where((d) => !excluded.contains(d.studentNo)).toList();

  Future<void> start() async {
    if (status == RadarStatus.scanning || status == RadarStatus.starting) return;
    status = RadarStatus.starting;
    _notify();

    _advertSub ??= _scanner.adverts.listen(_onAdvert);
    _stateSub ??= _scanner.bluetoothOn.listen((on) {
      if (_disposed) return;
      if (!on && status == RadarStatus.scanning) {
        status = RadarStatus.bluetoothOff;
        _notify();
      } else if (on && status == RadarStatus.bluetoothOff) {
        unawaited(start()); // the assistant switched Bluetooth on: carry on automatically
      }
    });

    final result = await _scanner.start();
    switch (result) {
      case ScanStartResult.ok:
        status = RadarStatus.scanning;
        break;
      case ScanStartResult.permissionDenied:
        status = RadarStatus.needsPermission;
        break;
      case ScanStartResult.bluetoothOff:
        status = RadarStatus.bluetoothOff;
        break;
      case ScanStartResult.unsupported:
        status = RadarStatus.unsupported;
        break;
      case ScanStartResult.error:
        status = RadarStatus.error;
        break;
    }
    _notify();
  }

  Future<void> stop() async {
    await _scanner.stop();
    if (status == RadarStatus.scanning || status == RadarStatus.starting) status = RadarStatus.idle;
    _notify();
  }

  Future<void> turnBluetoothOn() async {
    if (await _scanner.turnOn()) await start();
  }

  void _onAdvert(RawAdvert advert) {
    if (status != RadarStatus.scanning) return;
    var changed = false;
    for (final uuid in advert.serviceUuids) {
      final fresh = book.onAdvert(uuid, advert.rssi, _serverNow(), threshold: threshold);
      changed = true;
      if (fresh != null) onNewDetection?.call(fresh);
      final seen = book.lastTouched;
      if (seen != null && seen.bestRssi > threshold) replies?.maybeReply(seen.studentNo, seen.macHex);
    }
    if (changed) _notify();
  }

  void setThreshold(int value) {
    threshold = value;
    _notify();
  }

  void toggle(int studentNo) {
    if (!excluded.remove(studentNo)) excluded.add(studentNo);
    _notify();
  }

  /// After a confirmation: students the server accepted or saved for later are done; rejected ones stay listed.
  void applyOutcome(BulkOutcome outcome) {
    book.markConfirmed([...outcome.accepted, ...outcome.queued, ...outcome.alreadyPresent]);
    excluded.removeAll([...outcome.accepted, ...outcome.queued, ...outcome.alreadyPresent]);
    _notify();
  }

  void clear() {
    book.clear();
    excluded.clear();
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _advertSub?.cancel();
    _stateSub?.cancel();
    unawaited(_scanner.stop());
    unawaited(replies?.dispose() ?? Future<void>.value());
    super.dispose();
  }
}
