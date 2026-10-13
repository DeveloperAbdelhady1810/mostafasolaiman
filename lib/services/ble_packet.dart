import 'dart:typed_data';

/// The student app's Bluetooth packet is one 128-bit service UUID (the only free-form data an iPhone may
/// advertise). Its 16 bytes are:
///
///   `0x4D 0x53` ("MS")  | version 0x01 | student_no (4 bytes, big-endian) | MAC (9 bytes)
///
/// The assistant's reply uses the marker `0x4D 0x41` ("MA") with the same layout.
/// Keep identical to the student app's `lib/services/ble_packet.dart` (same test vector in both repos).
class BlePacket {
  static const int length = 16;
  static const int version = 1;
  static const int markerM = 0x4D;
  static const int studentMarker = 0x53; // 'S' -> a student's own broadcast
  static const int assistantMarker = 0x41; // 'A' -> an assistant's reply

  static String bytesToUuid(List<int> bytes) {
    assert(bytes.length == length);
    final h = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
  }

  /// Any textual UUID form -> 16 bytes, or null when it is not a full 128-bit UUID.
  static Uint8List? uuidToBytes(String uuid) {
    final hex = uuid.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
    if (hex.length != 32) return null;
    final out = Uint8List(length);
    for (var i = 0; i < length; i++) {
      out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }

  static List<int> _hexToBytes(String hex) =>
      List<int>.generate(hex.length ~/ 2, (i) => int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16));

  static Uint8List _build(int marker2, int studentNo, List<int> mac) {
    final b = BytesBuilder()
      ..add([markerM, marker2, version])
      ..add((ByteData(4)..setUint32(0, studentNo, Endian.big)).buffer.asUint8List())
      ..add(mac);
    return b.toBytes();
  }

  /// The reply that tells a student's phone "your assistant heard you": echoes the MAC that was heard.
  static String replyUuid(int studentNo, String macHex) => bytesToUuid(_build(assistantMarker, studentNo, _hexToBytes(macHex)));

  /// Parses a UUID that carries one of our packets; null for any other Bluetooth device's UUID.
  static ParsedBlePacket? parse(String uuid) {
    final bytes = uuidToBytes(uuid);
    if (bytes == null || bytes[0] != markerM || bytes[2] != version) return null;
    final kind = bytes[1];
    if (kind != studentMarker && kind != assistantMarker) return null;
    final studentNo = ByteData.sublistView(bytes, 3, 7).getUint32(0, Endian.big);
    if (studentNo == 0) return null;
    return ParsedBlePacket(
      isReply: kind == assistantMarker,
      studentNo: studentNo,
      macHex: bytes.sublist(7, 16).map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
    );
  }
}

class ParsedBlePacket {
  const ParsedBlePacket({required this.isReply, required this.studentNo, required this.macHex});

  /// true = an assistant's reply, false = a student's own broadcast.
  final bool isReply;
  final int studentNo;
  final String macHex;
}
