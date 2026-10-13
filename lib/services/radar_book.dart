import 'ble_packet.dart';

/// One student seen by the radar. [macHex]/[detectedAt] are from the MOST RECENT sighting (that MAC is
/// what the server verifies, against the server-clock time it was heard); [bestRssi] is the closest the
/// student ever got.
class Detection {
  Detection({
    required this.studentNo,
    required this.macHex,
    required this.detectedAt,
    required this.rssi,
    required this.firstSeen,
  })  : bestRssi = rssi,
        lastSeen = firstSeen;

  final int studentNo;
  String macHex;
  int detectedAt; // unix seconds, SERVER clock
  int rssi; // latest
  int bestRssi;
  int sightings = 1;
  final DateTime firstSeen;
  DateTime lastSeen;

  /// The server accepted (or queued) this student.
  bool confirmed = false;
}

/// Pure bookkeeping for the Classroom Radar: keeps one entry per student, ignores anything that is not
/// one of our packets, and decides which students count as "in the room" for a given signal threshold.
class RadarBook {
  RadarBook({this.maxStudents = 600});

  /// Protects the list from a phone flooding fake packets.
  final int maxStudents;

  final Map<int, Detection> _all = {};

  Iterable<Detection> get all => _all.values;
  Detection? byStudentNo(int no) => _all[no];
  int get totalSeen => _all.length;

  /// Feeds one received advertisement. Returns the [Detection] when this advert made the student
  /// newly count as in the room (first time their signal passes [threshold]); otherwise null.
  Detection? onAdvert(String serviceUuid, int rssi, int serverNow, {required int threshold, DateTime? now}) {
    final packet = BlePacket.parse(serviceUuid);
    if (packet == null || packet.isReply) return null; // other devices, or an assistant's reply

    final at = now ?? DateTime.now();
    var d = _all[packet.studentNo];
    final wasIn = d != null && d.bestRssi > threshold;

    if (d == null) {
      if (_all.length >= maxStudents) return null;
      d = Detection(
        studentNo: packet.studentNo,
        macHex: packet.macHex,
        detectedAt: serverNow,
        rssi: rssi,
        firstSeen: at,
      );
      _all[packet.studentNo] = d;
    } else {
      d.macHex = packet.macHex;
      d.detectedAt = serverNow;
      d.rssi = rssi;
      if (rssi > d.bestRssi) d.bestRssi = rssi;
      d.sightings++;
      d.lastSeen = at;
    }

    final isIn = d.bestRssi > threshold;
    return (!wasIn && isIn && !d.confirmed) ? d : null;
  }

  /// Students that count as in the room and are not yet confirmed, newest first.
  List<Detection> pending(int threshold) => _all.values
      .where((d) => !d.confirmed && d.bestRssi > threshold)
      .toList()
    ..sort((a, b) => b.lastSeen.compareTo(a.lastSeen));

  /// Students already confirmed (shown ticked at the bottom of the list).
  List<Detection> confirmedList() => _all.values.where((d) => d.confirmed).toList()
    ..sort((a, b) => b.lastSeen.compareTo(a.lastSeen));

  void markConfirmed(Iterable<int> studentNos) {
    for (final no in studentNos) {
      _all[no]?.confirmed = true;
    }
  }

  void clear() => _all.clear();
}
