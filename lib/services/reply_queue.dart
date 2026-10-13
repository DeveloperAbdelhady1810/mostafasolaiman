import 'dart:async';
import 'ble_packet.dart';
import 'reply_advertiser.dart';

/// Tells each detected student's phone "your assistant heard you" (the student app then plays its tick).
///
/// A phone can only advertise one packet at a time, so replies go out one after another, [burst] each:
/// long enough for the student's scanner to catch it, short enough that a whole class is answered
/// well inside the students' 60 s broadcast window. The reply echoes the MAC the student broadcast,
/// which is how the student's phone knows it is really for them.
///
/// A reply can be missed (the student's scanner was still starting, a hand over the phone...), so a
/// student who keeps being heard is answered again, up to [maxPerSession] times, at least [spacing]
/// apart. Hearing them again after a long silence ([sessionGap]) starts a new session.
class ReplyQueue {
  ReplyQueue(
    this._advertiser, {
    this.burst = const Duration(milliseconds: 1200),
    this.spacing = const Duration(seconds: 8),
    this.maxPerSession = 3,
    this.sessionGap = const Duration(seconds: 70),
    this.maxQueue = 80,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final ReplyAdvertiser _advertiser;
  final Duration burst;
  final Duration spacing;
  final int maxPerSession;
  final Duration sessionGap;
  final int maxQueue;
  final DateTime Function() _now;

  final Map<int, String> _waiting = {}; // student_no -> mac, insertion ordered
  final Map<int, DateTime> _lastReply = {};
  final Map<int, DateTime> _lastHeard = {};
  final Map<int, int> _sessionReplies = {};
  bool _running = false;
  bool _disposed = false;
  bool? _canAdvertise;

  int get waiting => _waiting.length;
  int repliesSent = 0;

  /// Call every time a student in range is heard.
  void maybeReply(int studentNo, String macHex) {
    if (_disposed || _canAdvertise == false) return;
    final now = _now();

    final heard = _lastHeard[studentNo];
    if (heard != null && now.difference(heard) > sessionGap) _sessionReplies[studentNo] = 0; // new broadcast
    _lastHeard[studentNo] = now;

    if ((_sessionReplies[studentNo] ?? 0) >= maxPerSession) return;
    final last = _lastReply[studentNo];
    if (last != null && now.difference(last) < spacing) return;

    if (_waiting.containsKey(studentNo)) {
      _waiting[studentNo] = macHex; // keep the freshest code for the same student
      return;
    }
    if (_waiting.length >= maxQueue) return;
    _waiting[studentNo] = macHex;
    unawaited(_pump());
  }

  Future<void> _pump() async {
    if (_running) return;
    _running = true;
    try {
      _canAdvertise ??= await _advertiser.prepare();
      if (_canAdvertise != true) {
        _waiting.clear();
        return;
      }
      while (_waiting.isNotEmpty && !_disposed) {
        final no = _waiting.keys.first;
        final mac = _waiting.remove(no)!;
        _lastReply[no] = _now();
        _sessionReplies[no] = (_sessionReplies[no] ?? 0) + 1;
        if (await _advertiser.start(BlePacket.replyUuid(no, mac))) repliesSent++;
        await Future<void>.delayed(burst);
        await _advertiser.stop();
      }
    } finally {
      _running = false;
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    _waiting.clear();
    await _advertiser.stop();
  }
}
