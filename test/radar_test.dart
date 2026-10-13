import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:attendance_assistant/models/center.dart';
import 'package:attendance_assistant/models/course.dart';
import 'package:attendance_assistant/models/roster_student.dart';
import 'package:attendance_assistant/providers/attendance_provider.dart';
import 'package:attendance_assistant/providers/auth_provider.dart';
import 'package:attendance_assistant/providers/radar_provider.dart';
import 'package:attendance_assistant/screens/radar_screen.dart';
import 'package:attendance_assistant/services/api_client.dart';
import 'package:attendance_assistant/services/ble_packet.dart';
import 'package:attendance_assistant/services/ble_scanner.dart';
import 'package:attendance_assistant/services/radar_book.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Shared test vector: secret 0x00..0x1f, student 10001, counter 59000000 -> this packet.
const _uuid10001 = '4d530100-0027-11b4-a0fd-ce853f03dfc5';
const _mac10001 = 'b4a0fdce853f03dfc5';

/// A student's broadcast packet (marker "MS"), built byte by byte.
String _uuidFor(int studentNo, {String mac = _mac10001}) {
  final b = BytesBuilder()
    ..add([0x4D, 0x53, 0x01])
    ..add((ByteData(4)..setUint32(0, studentNo, Endian.big)).buffer.asUint8List())
    ..add(List<int>.generate(9, (i) => int.parse(mac.substring(i * 2, i * 2 + 2), radix: 16)));
  return BlePacket.bytesToUuid(b.toBytes());
}

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

class FakeScanner implements BleScanner {
  final _adverts = StreamController<RawAdvert>.broadcast();
  final _state = StreamController<bool>.broadcast();
  ScanStartResult result = ScanStartResult.ok;
  int starts = 0;
  int stops = 0;
  bool turnOnWorks = true;

  @override
  Stream<RawAdvert> get adverts => _adverts.stream;
  @override
  Stream<bool> get bluetoothOn => _state.stream;
  @override
  Future<ScanStartResult> start() async {
    starts++;
    return result;
  }

  @override
  Future<void> stop() async => stops++;
  @override
  Future<bool> turnOn() async {
    if (turnOnWorks) result = ScanStartResult.ok;
    return turnOnWorks;
  }

  void hear(String uuid, int rssi) => _adverts.add(RawAdvert([uuid], rssi));
  void adapter(bool on) => _state.add(on);
}

Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  group('BlePacket (assistant copy)', () {
    test('matches the shared test vector and the student app', () {
      expect(_uuidFor(10001), _uuid10001);
      final p = BlePacket.parse(_uuid10001)!;
      expect(p.isReply, isFalse);
      expect(p.studentNo, 10001);
      expect(p.macHex, _mac10001);
    });

    test('reply packet echoes student and MAC with the "MA" marker', () {
      expect(BlePacket.replyUuid(10001, _mac10001), '4d410100-0027-11b4-a0fd-ce853f03dfc5');
      final p = BlePacket.parse(BlePacket.replyUuid(10001, _mac10001))!;
      expect(p.isReply, isTrue);
      expect(p.studentNo, 10001);
      expect(p.macHex, _mac10001);
    });

    test('foreign devices are ignored', () {
      expect(BlePacket.parse('0000180f-0000-1000-8000-00805f9b34fb'), isNull);
      expect(BlePacket.parse('180f'), isNull);
      expect(BlePacket.parse('4d530200-0027-11b4-a0fd-ce853f03dfc5'), isNull);
    });
  });

  group('RadarBook', () {
    test('keeps one entry per student and the latest MAC + server time', () {
      final book = RadarBook();
      book.onAdvert(_uuid10001, -60, 1000, threshold: -75);
      final second = _uuidFor(10001, mac: 'aabbccddeeff001122');
      book.onAdvert(second, -58, 1030, threshold: -75);

      expect(book.totalSeen, 1);
      final d = book.byStudentNo(10001)!;
      expect(d.macHex, 'aabbccddeeff001122');
      expect(d.detectedAt, 1030);
      expect(d.bestRssi, -58);
      expect(d.sightings, 2);
    });

    test('only the first time a student passes the threshold counts as a new detection', () {
      final book = RadarBook();
      expect(book.onAdvert(_uuid10001, -90, 1000, threshold: -75), isNull); // too far
      expect(book.onAdvert(_uuid10001, -70, 1001, threshold: -75), isNotNull); // came closer
      expect(book.onAdvert(_uuid10001, -50, 1002, threshold: -75), isNull); // already counted
    });

    test('a weaker packet is not "new" and does not lower the best signal', () {
      final book = RadarBook();
      book.onAdvert(_uuid10001, -50, 1000, threshold: -75);
      book.onAdvert(_uuid10001, -88, 1001, threshold: -75);
      expect(book.byStudentNo(10001)!.bestRssi, -50);
      expect(book.pending(-75), hasLength(1));
    });

    test('threshold decides who is in the room, live', () {
      final book = RadarBook();
      book.onAdvert(_uuidFor(10001), -60, 1000, threshold: -75);
      book.onAdvert(_uuidFor(10002), -82, 1000, threshold: -75);

      expect(book.pending(-75).map((d) => d.studentNo), [10001]);
      expect(book.pending(-90).map((d) => d.studentNo).toSet(), {10001, 10002});
      expect(book.pending(-55), isEmpty);
    });

    test('assistant replies and unrelated devices are not students', () {
      final book = RadarBook();
      expect(book.onAdvert(BlePacket.replyUuid(10001, _mac10001), -40, 1000, threshold: -75), isNull);
      expect(book.onAdvert('0000180f-0000-1000-8000-00805f9b34fb', -40, 1000, threshold: -75), isNull);
      expect(book.totalSeen, 0);
    });

    test('confirmed students leave the pending list', () {
      final book = RadarBook();
      book.onAdvert(_uuidFor(10001), -60, 1000, threshold: -75);
      book.markConfirmed([10001]);
      expect(book.pending(-75), isEmpty);
      expect(book.confirmedList().single.studentNo, 10001);
      expect(book.onAdvert(_uuidFor(10001), -55, 1010, threshold: -75), isNull); // not "new" again
    });

    test('a flood of fake packets cannot grow the list without limit', () {
      final book = RadarBook(maxStudents: 5);
      for (var i = 1; i <= 50; i++) {
        book.onAdvert(_uuidFor(10000 + i), -50, 1000, threshold: -75);
      }
      expect(book.totalSeen, 5);
    });
  });

  group('RadarProvider', () {
    late FakeScanner scanner;
    late RadarProvider radar;
    late List<int> chimes;

    setUp(() {
      scanner = FakeScanner();
      chimes = [];
      radar = RadarProvider(scanner: scanner, serverNow: () => 5000)..onNewDetection = (d) => chimes.add(d.studentNo);
    });
    tearDown(() => radar.dispose());

    test('start -> scanning; adverts become detections with one chime per student', () async {
      await radar.start();
      expect(radar.status, RadarStatus.scanning);

      scanner.hear(_uuidFor(10001), -60);
      scanner.hear(_uuidFor(10001), -58);
      scanner.hear(_uuidFor(10002), -62);
      await _settle();

      expect(radar.pending.map((d) => d.studentNo).toSet(), {10001, 10002});
      expect(chimes, [10001, 10002]);
      expect(radar.pending.first.detectedAt, 5000);
    });

    test('students outside the range are listed as hidden, not counted', () async {
      await radar.start();
      scanner.hear(_uuidFor(10001), -90);
      await _settle();

      expect(radar.pending, isEmpty);
      expect(radar.book.totalSeen, 1);
      expect(chimes, isEmpty);

      radar.setThreshold(-95); // widen the range
      expect(radar.pending, hasLength(1));
    });

    test('unticking a student keeps them out of the confirm list', () async {
      await radar.start();
      scanner.hear(_uuidFor(10001), -60);
      scanner.hear(_uuidFor(10002), -60);
      await _settle();

      radar.toggle(10002);
      expect(radar.selected.map((d) => d.studentNo), [10001]);
      radar.toggle(10002);
      expect(radar.selected, hasLength(2));
    });

    test('permission denied / Bluetooth off / unsupported states', () async {
      scanner.result = ScanStartResult.permissionDenied;
      await radar.start();
      expect(radar.status, RadarStatus.needsPermission);

      scanner.result = ScanStartResult.bluetoothOff;
      await radar.start();
      expect(radar.status, RadarStatus.bluetoothOff);

      scanner.result = ScanStartResult.unsupported;
      await radar.start();
      expect(radar.status, RadarStatus.unsupported);
    });

    test('switching Bluetooth on resumes scanning by itself', () async {
      scanner.result = ScanStartResult.bluetoothOff;
      await radar.start();
      expect(radar.status, RadarStatus.bluetoothOff);

      scanner.result = ScanStartResult.ok;
      scanner.adapter(true);
      await _settle();
      await _settle();

      expect(radar.status, RadarStatus.scanning);
    });

    test('Bluetooth switched off mid-scan is reported', () async {
      await radar.start();
      scanner.adapter(false);
      await _settle();
      expect(radar.status, RadarStatus.bluetoothOff);
    });

    test('adverts are ignored while not scanning', () async {
      scanner.hear(_uuidFor(10001), -50);
      await _settle();
      expect(radar.book.totalSeen, 0);
    });
  });

  group('confirmDetections (server verification of Bluetooth detections)', () {
    late AttendanceProvider provider;
    late List<http.Request> requests;
    late Future<http.Response> Function(http.Request) handler;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      requests = [];
      handler = (_) async => _json({});
      provider = AttendanceProvider(
        api: ApiClient(client: MockClient((req) async {
          requests.add(req);
          return handler(req);
        })),
      )
        ..selectedCourse = AttendanceCourse(id: 7, title: 'Algebra 1')
        ..selectedCenter = AttendanceCenter(id: 3, name: 'Nasr City')
        ..roster = [
          RosterStudent(id: 11, name: 'Omar Tester', studentNumber: 10001),
          RosterStudent(id: 12, name: 'Sara Tester', studentNumber: 10002),
        ];
    });

    List<Detection> sightings(Map<int, int> studentNoToRssi) {
      final book = RadarBook(maxStudents: 1000);
      studentNoToRssi.forEach((no, rssi) => book.onAdvert(_uuidFor(no), rssi, 4242, threshold: -95));
      return book.all.toList();
    }

    test('sends method=ble with rssi, the heard MAC and the sighting time', () async {
      handler = (_) async => _json({
            'accepted': [
              {'student_id': 11, 'student_no': 10001, 'name': 'Omar Tester'}
            ],
            'newly_marked': 1,
            'rejected': [],
          });

      final outcome = await provider.confirmDetections('tok', sightings({10001: -61}));

      expect(outcome.accepted, [10001]);
      expect(provider.roster.firstWhere((s) => s.id == 11).status, 'present');
      final body = jsonDecode(requests.single.body) as Map<String, dynamic>;
      expect(body['course_id'], 7);
      expect(body['center_id'], 3);
      final e = (body['entries'] as List).single as Map<String, dynamic>;
      expect(e['student_no'], 10001);
      expect(e['method'], 'ble');
      expect(e['rssi'], -61);
      expect(e['detected_at'], 4242);
      expect(e['mac'], hasLength(18));
    });

    test('rejected students are reported with a readable reason and stay absent', () async {
      handler = (_) async => _json({
            'accepted': [
              {'student_id': 11, 'student_no': 10001, 'name': 'Omar Tester'}
            ],
            'newly_marked': 1,
            'rejected': [
              {'student_no': 10002, 'reason': 'bad_token'}
            ],
          });

      final outcome = await provider.confirmDetections('tok', sightings({10001: -60, 10002: -60}));

      expect(outcome.accepted, [10001]);
      expect(outcome.rejected.single.studentNo, 10002);
      expect(outcome.rejected.single.name, 'Sara Tester');
      expect(outcome.rejected.single.message, contains('expired'));
      expect(provider.roster.firstWhere((s) => s.id == 12).status, 'absent');
    });

    test('offline: saved for later, shown unverified, and sent before Submit', () async {
      handler = (_) async => throw const SocketException('no route');

      final outcome = await provider.confirmDetections('tok', sightings({10001: -60}));

      expect(outcome.queued, [10001]);
      expect(outcome.accepted, isEmpty);
      expect(provider.pendingScans.single.method, 'ble');
      expect(provider.unverifiedStudentIds, contains(11));

      handler = (req) async {
        if (req.url.path.endsWith('/assistant/attendance/bulk')) {
          return _json({
            'accepted': [
              {'student_id': 11, 'student_no': 10001, 'name': 'Omar Tester'}
            ],
            'newly_marked': 1,
            'rejected': [],
          });
        }
        return _json({'present': 1});
      };
      final submitted = await provider.submitAttendance('tok');
      expect(submitted, isNotNull);
      expect(provider.pendingScans, isEmpty);
      expect(provider.unverifiedStudentIds, isEmpty);
    });

    test('feature off on the server: whole batch fails with a clear message, nothing is queued', () async {
      handler = (_) async => _json({'message': 'Bluetooth attendance is not enabled yet.'}, 403);

      final outcome = await provider.confirmDetections('tok', sightings({10001: -60}));

      expect(outcome.failureMessage, contains('not enabled'));
      expect(outcome.handled, 0);
      expect(provider.pendingScans, isEmpty);
      expect(provider.bleEnabled, isFalse);
    });

    test('a student already verified (e.g. by QR) is not sent again', () async {
      handler = (_) async => _json({
            'accepted': [
              {'student_id': 11, 'student_no': 10001, 'name': 'Omar Tester'}
            ],
            'newly_marked': 1,
            'rejected': [],
          });
      await provider.confirmDetections('tok', sightings({10001: -60}));
      requests.clear();

      final outcome = await provider.confirmDetections('tok', sightings({10001: -60}));

      expect(outcome.alreadyPresent, [10001]);
      expect(requests, isEmpty);
    });

    test('more than 300 detections are split into several requests', () async {
      handler = (req) async => _json({'accepted': [], 'newly_marked': 0, 'rejected': []});
      final many = sightings({for (var i = 0; i < 650; i++) 20000 + i: -60});

      await provider.confirmDetections('tok', many);

      final sizes = requests.map((r) => ((jsonDecode(r.body) as Map)['entries'] as List).length).toList();
      expect(sizes, [300, 300, 50]);
    });

    test('loadFeatures picks up the server default signal threshold', () async {
      handler = (_) async => _json({'ble_enabled': true, 'rssi_threshold': -70});
      await provider.loadFeatures('tok');
      expect(provider.bleEnabled, isTrue);
      expect(provider.rssiThreshold, -70);
    });
  });

  group('RadarScreen', () {
    Future<(FakeScanner, AttendanceProvider, List<http.Request>)> pumpRadar(WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);

      final scanner = FakeScanner();
      final requests = <http.Request>[];
      final attendance = AttendanceProvider(
        api: ApiClient(client: MockClient((req) async {
          requests.add(req);
          return _json({
            'accepted': [
              {'student_id': 11, 'student_no': 10001, 'name': 'Omar Tester'}
            ],
            'newly_marked': 1,
            'rejected': [],
          });
        })),
      )
        ..selectedCourse = AttendanceCourse(id: 7, title: 'Algebra 1')
        ..selectedCenter = AttendanceCenter(id: 3, name: 'Nasr City')
        ..roster = [RosterStudent(id: 11, name: 'Omar Tester', studentNumber: 10001)];

      SharedPreferences.setMockInitialValues({'auth_token': 'tok', 'auth_user': '{"role":"assistant"}'});
      final auth = AuthProvider();
      await auth.tryAutoLogin();

      await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider<AuthProvider>.value(value: auth),
          ChangeNotifierProvider<AttendanceProvider>.value(value: attendance),
        ],
        child: MaterialApp(home: RadarScreen(scanner: scanner)),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      return (scanner, attendance, requests);
    }

    testWidgets('shows detected students by roster name and confirms them in one tap', (tester) async {
      final (scanner, attendance, requests) = await pumpRadar(tester);

      expect(find.text('Listening for students...'), findsOneWidget);
      expect(find.text('Nobody to confirm yet'), findsOneWidget);

      scanner.hear(_uuid10001, -58);
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('Omar Tester'), findsOneWidget);
      expect(find.text('1 in the room'), findsOneWidget);
      expect(find.text('Confirm 1 student'), findsOneWidget);

      await tester.tap(find.byKey(const Key('radar_confirm')));
      await tester.pumpAndSettle();

      expect(requests, hasLength(1));
      expect(find.textContaining('1 verified and marked present'), findsOneWidget);
      expect(attendance.roster.single.status, 'present');

      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(find.text('Confirmed (1)'), findsOneWidget);
      expect(find.text('Nobody to confirm yet'), findsOneWidget);
    });

    testWidgets('Bluetooth off shows a clear state', (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      final scanner = FakeScanner()..result = ScanStartResult.bluetoothOff;

      await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider<AuthProvider>(create: (_) => AuthProvider()),
          ChangeNotifierProvider<AttendanceProvider>(create: (_) => AttendanceProvider()),
        ],
        child: MaterialApp(home: RadarScreen(scanner: scanner)),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('Bluetooth is off'), findsOneWidget);
      expect(find.text('Turn on'), findsOneWidget);
    });
  });
}
