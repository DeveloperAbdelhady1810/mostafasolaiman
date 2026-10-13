import '../config.dart';

/// The text inside a student's rotating QR: `MSQ1:<student_no>:<counter>:<mac>`.
/// The assistant never checks the MAC itself (only the server holds the secrets).
class RotatingCode {
  final int studentNo;
  final int counter;
  final String mac;

  const RotatingCode(this.studentNo, this.counter, this.mac);

  static final _macPattern = RegExp(r'^[0-9a-fA-F]{18}$');

  /// Returns null when [raw] is not a well-formed rotating code.
  static RotatingCode? tryParse(String raw) {
    final text = raw.trim();
    if (!text.startsWith(rotatingQrPrefix)) return null;
    final parts = text.split(':');
    if (parts.length != 4) return null;
    final no = int.tryParse(parts[1]);
    final counter = int.tryParse(parts[2]);
    final mac = parts[3];
    if (no == null || no <= 0 || counter == null || counter <= 0) return null;
    if (!_macPattern.hasMatch(mac)) return null;
    return RotatingCode(no, counter, mac.toLowerCase());
  }
}

/// One detection waiting to be verified by the server (kept on disk so it survives an app restart).
class PendingScan {
  final int courseId;
  final int centerId;
  final String date; // yyyy-MM-dd
  final int studentNo;
  final String mac;
  final int detectedAt; // unix seconds, SERVER clock
  final String method; // 'qr' now, 'ble' later
  final int? rssi;

  const PendingScan({
    required this.courseId,
    required this.centerId,
    required this.date,
    required this.studentNo,
    required this.mac,
    required this.detectedAt,
    this.method = 'qr',
    this.rssi,
  });

  String get groupKey => '$courseId|$centerId|$date';

  Map<String, dynamic> toEntryJson() => {
        'student_no': studentNo,
        'mac': mac,
        'method': method,
        'detected_at': detectedAt,
        if (rssi != null) 'rssi': rssi,
      };

  Map<String, dynamic> toJson() => {
        'course_id': courseId,
        'center_id': centerId,
        'date': date,
        'student_no': studentNo,
        'mac': mac,
        'detected_at': detectedAt,
        'method': method,
        'rssi': rssi,
      };

  factory PendingScan.fromJson(Map<String, dynamic> j) => PendingScan(
        courseId: j['course_id'] as int,
        centerId: j['center_id'] as int,
        date: j['date'] as String,
        studentNo: j['student_no'] as int,
        mac: j['mac'] as String,
        detectedAt: j['detected_at'] as int,
        method: (j['method'] as String?) ?? 'qr',
        rssi: j['rssi'] as int?,
      );
}

/// One student the server refused during a bulk confirmation.
class BulkRejection {
  const BulkRejection(this.studentNo, this.name, this.message);
  final int studentNo;
  final String? name;
  final String message;
}

/// Result of confirming a batch of Bluetooth detections.
class BulkOutcome {
  const BulkOutcome({
    this.accepted = const [],
    this.rejected = const [],
    this.queued = const [],
    this.alreadyPresent = const [],
    this.failureMessage,
  });

  /// Student numbers the server verified and marked present.
  final List<int> accepted;
  final List<BulkRejection> rejected;

  /// Saved on the phone (no connection) - will be verified later.
  final List<int> queued;

  /// Already verified earlier in this session (nothing to do).
  final List<int> alreadyPresent;

  /// Set when the whole batch failed for a reason that retrying cannot fix (e.g. the feature is off).
  final String? failureMessage;

  int get handled => accepted.length + queued.length + alreadyPresent.length;
}

enum ScanKind {
  /// Server confirmed the code (or a legacy ID code matched the roster).
  verified,

  /// No connection: saved, will be verified as soon as the phone is online.
  pending,

  /// Already marked present in this session.
  duplicate,

  /// The server refused it (expired/invalid code, unknown student ...).
  rejected,

  /// Not a student code at all.
  invalid,
}

/// What the scanner screen shows after each code.
class ScanFeedback {
  final ScanKind kind;
  final String message;

  const ScanFeedback(this.kind, this.message);

  bool get isSuccess => kind == ScanKind.verified || kind == ScanKind.pending;
  bool get isWarning => kind == ScanKind.duplicate;
  bool get isError => kind == ScanKind.rejected || kind == ScanKind.invalid;
}
