import 'dart:convert';
import 'dart:io';

import 'package:attendance_assistant/models/center.dart';
import 'package:attendance_assistant/models/course.dart';
import 'package:attendance_assistant/models/roster_student.dart';
import 'package:attendance_assistant/models/scan.dart';
import 'package:attendance_assistant/providers/attendance_provider.dart';
import 'package:attendance_assistant/services/api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _code = 'MSQ1:10001:59730342:0f4e4b872ee1553e3d';

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

class _Harness {
  _Harness() {
    SharedPreferences.setMockInitialValues({});
    client = MockClient((req) async {
      requests.add(req);
      return handler(req);
    });
    provider = AttendanceProvider(api: ApiClient(client: client))
      ..selectedCourse = AttendanceCourse(id: 7, title: 'Algebra 1')
      ..selectedCenter = AttendanceCenter(id: 3, name: 'Nasr City')
      ..roster = [
        RosterStudent(id: 11, name: 'Omar Tester', studentNumber: 10001),
        RosterStudent(id: 12, name: 'Sara Tester', studentNumber: 10002),
      ];
  }

  late final MockClient client;
  late final AttendanceProvider provider;
  final List<http.BaseRequest> requests = [];
  Future<http.Response> Function(http.Request) handler = (_) async => _json({});

  RosterStudent student(int no) => provider.roster.firstWhere((s) => s.studentNumber == no);
  List<http.BaseRequest> get bulkCalls => requests.where((r) => r.url.path.endsWith('/assistant/attendance/bulk')).toList();
}

Map<String, dynamic> _acceptedFor(int id, int no, String name) => {
      'accepted': [
        {'student_id': id, 'student_no': no, 'name': name}
      ],
      'newly_marked': 1,
      'rejected': [],
    };

void main() {
  group('RotatingCode.tryParse', () {
    test('parses a well-formed code', () {
      final c = RotatingCode.tryParse(_code)!;
      expect(c.studentNo, 10001);
      expect(c.counter, 59730342);
      expect(c.mac, '0f4e4b872ee1553e3d');
    });

    test('rejects malformed codes', () {
      expect(RotatingCode.tryParse('MSQ1:abc:1:0f4e4b872ee1553e3d'), isNull);
      expect(RotatingCode.tryParse('MSQ1:10001:59730342:0f4e4b87'), isNull); // short mac
      expect(RotatingCode.tryParse('MSQ1:10001:59730342:zz4e4b872ee1553e3d'), isNull); // not hex
      expect(RotatingCode.tryParse('MSQ1:10001:59730342'), isNull);
      expect(RotatingCode.tryParse('MSQ1:0:59730342:0f4e4b872ee1553e3d'), isNull);
      expect(RotatingCode.tryParse('LQ-010001'), isNull);
    });
  });

  group('rotating code scan', () {
    test('verified by the server -> present, request carries course/center/entry', () async {
      final h = _Harness();
      h.handler = (_) async => _json(_acceptedFor(11, 10001, 'Omar Tester'));

      final before = ApiClient.serverNow();
      final fb = await h.provider.handleScan('tok123', _code);
      final after = ApiClient.serverNow();

      expect(fb.kind, ScanKind.verified);
      expect(fb.message, contains('Omar Tester'));
      expect(h.student(10001).status, 'present');
      expect(h.provider.unverifiedStudentIds, isEmpty);

      final call = h.bulkCalls.single as http.Request;
      expect(call.headers['Authorization'], 'Bearer tok123');
      final body = jsonDecode(call.body) as Map<String, dynamic>;
      expect(body['course_id'], 7);
      expect(body['center_id'], 3);
      expect(body['date'], matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')));
      final e = (body['entries'] as List).single as Map<String, dynamic>;
      expect(e['student_no'], 10001);
      expect(e['mac'], '0f4e4b872ee1553e3d');
      expect(e['method'], 'qr');
      expect(e['detected_at'], inInclusiveRange(before, after));
    });

    test('scanning the same student again does not call the server', () async {
      final h = _Harness();
      h.handler = (_) async => _json(_acceptedFor(11, 10001, 'Omar Tester'));

      await h.provider.handleScan('t', _code);
      final fb = await h.provider.handleScan('t', _code);

      expect(fb.kind, ScanKind.duplicate);
      expect(h.bulkCalls, hasLength(1));
    });

    test('expired / invalid code is rejected and nobody is marked present', () async {
      final h = _Harness();
      h.handler = (_) async => _json({
            'accepted': [],
            'newly_marked': 0,
            'rejected': [
              {'student_no': 10001, 'reason': 'bad_token'}
            ],
          });

      final fb = await h.provider.handleScan('t', _code);

      expect(fb.kind, ScanKind.rejected);
      expect(fb.message, contains('expired'));
      expect(h.student(10001).status, 'absent');
      expect(h.provider.pendingScans, isEmpty);
    });

    test('a student not on the roster is added as a walk-in', () async {
      final h = _Harness();
      h.handler = (_) async => _json(_acceptedFor(99, 10003, 'Walk In'));

      final fb = await h.provider.handleScan('t', 'MSQ1:10003:59730342:0f4e4b872ee1553e3d');

      expect(fb.kind, ScanKind.verified);
      final added = h.provider.roster.firstWhere((s) => s.id == 99);
      expect(added.status, 'present');
      expect(added.isWalkIn, isTrue);
    });

    test('feature switched off on the server -> clear message, not queued', () async {
      final h = _Harness();
      h.provider.bleEnabled = true;
      h.handler = (_) async => _json({'message': 'Bluetooth attendance is not enabled yet.'}, 403);

      final fb = await h.provider.handleScan('t', _code);

      expect(fb.kind, ScanKind.rejected);
      expect(h.provider.bleEnabled, isFalse);
      expect(h.provider.pendingScans, isEmpty);
      expect(h.student(10001).status, 'absent');
    });

    test('malformed payloads never reach the server', () async {
      final h = _Harness();

      for (final raw in ['hello', 'MSQ1:abc', 'MSQ1:10001:59730342:0f4e', 'LQ-xyz']) {
        final fb = await h.provider.handleScan('t', raw);
        expect(fb.kind, ScanKind.invalid, reason: raw);
      }
      expect(h.requests, isEmpty);
    });
  });

  group('offline queue', () {
    test('no connection -> saved as unverified, persisted, verified later', () async {
      final h = _Harness();
      h.handler = (_) async => throw const SocketException('no route');

      final fb = await h.provider.handleScan('t', _code);

      expect(fb.kind, ScanKind.pending);
      expect(h.student(10001).status, 'present');
      expect(h.provider.unverifiedStudentIds, contains(11));
      expect(h.provider.pendingScans, hasLength(1));

      final prefs = await SharedPreferences.getInstance();
      final saved = jsonDecode(prefs.getString('pending_scans')!) as List;
      expect(saved.single['student_no'], 10001);
      expect(saved.single['mac'], '0f4e4b872ee1553e3d');

      // back online
      h.handler = (_) async => _json(_acceptedFor(11, 10001, 'Omar Tester'));
      final ok = await h.provider.flushPending('t');

      expect(ok, isTrue);
      expect(h.provider.pendingScans, isEmpty);
      expect(h.provider.unverifiedStudentIds, isEmpty);
      expect(h.student(10001).status, 'present');
      expect(jsonDecode(prefs.getString('pending_scans')!), isEmpty);
    });

    test('a queued scan the server later rejects goes back to absent', () async {
      final h = _Harness();
      h.handler = (_) async => throw const SocketException('no route');
      await h.provider.handleScan('t', _code);
      expect(h.student(10001).status, 'present');

      h.handler = (_) async => _json({
            'accepted': [],
            'newly_marked': 0,
            'rejected': [
              {'student_no': 10001, 'reason': 'bad_token'}
            ],
          });
      await h.provider.flushPending('t');

      expect(h.student(10001).status, 'absent');
      expect(h.provider.pendingScans, isEmpty);
    });

    test('flush while still offline keeps everything queued', () async {
      final h = _Harness();
      h.handler = (_) async => throw const SocketException('no route');
      await h.provider.handleScan('t', _code);

      expect(await h.provider.flushPending('t'), isFalse);
      expect(h.provider.pendingScans, hasLength(1));
      expect(h.student(10001).status, 'present');
    });

    test('submit is blocked while scans are unverified (never submits unverified presence)', () async {
      final h = _Harness();
      h.handler = (_) async => throw const SocketException('no route');
      await h.provider.handleScan('t', _code);

      final result = await h.provider.submitAttendance('t');

      expect(result, isNull);
      expect(h.provider.error, contains('could not be verified'));
      expect(h.requests.where((r) => r.url.path.endsWith('/submit')), isEmpty);
    });

    test('submit flushes the queue first, then submits', () async {
      final h = _Harness();
      h.handler = (_) async => throw const SocketException('no route');
      await h.provider.handleScan('t', _code);

      h.handler = (req) async {
        if (req.url.path.endsWith('/assistant/attendance/bulk')) return _json(_acceptedFor(11, 10001, 'Omar Tester'));
        return _json({'present': 1, 'absent': 1});
      };
      final result = await h.provider.submitAttendance('t');

      expect(result, isNotNull);
      final order = h.requests.map((r) => r.url.path.split('/').last).toList();
      expect(order.indexOf('bulk'), lessThan(order.indexOf('submit')));
    });
  });

  group('legacy LQ- codes still work exactly as before', () {
    test('marks the rostered student present locally with no server call', () async {
      final h = _Harness();

      final fb = await h.provider.handleScan('t', 'LQ-010002');

      expect(fb.kind, ScanKind.verified);
      expect(h.student(10002).status, 'present');
      expect(h.requests, isEmpty);

      final again = await h.provider.handleScan('t', 'LQ-010002');
      expect(again.kind, ScanKind.duplicate);
    });

    test('unknown student falls back to the server search', () async {
      final h = _Harness();
      h.handler = (req) async {
        expect(req.url.path, endsWith('/assistant/students/search'));
        return _json({
          'students': [
            {'id': 55, 'name': 'Found Student', 'student_number': 10077}
          ]
        });
      };

      final fb = await h.provider.handleScan('t', 'LQ-010077');

      expect(fb.kind, ScanKind.verified);
      expect(h.provider.roster.firstWhere((s) => s.id == 55).status, 'present');
    });

    test('a failed search does not replace the roster with an error page', () async {
      final h = _Harness();
      h.handler = (_) async => _json({'message': 'boom'}, 500);

      final fb = await h.provider.handleScan('t', 'LQ-010077');

      expect(fb.kind, ScanKind.rejected);
      expect(h.provider.error, isNull);
    });
  });

  group('features + server clock', () {
    test('loadFeatures reads ble_enabled; a 404 turns it off', () async {
      final h = _Harness();
      h.handler = (_) async => _json({'ble_enabled': true, 'rssi_threshold': -75});
      await h.provider.loadFeatures('t');
      expect(h.provider.bleEnabled, isTrue);

      h.handler = (_) async => _json({'message': 'Not Found'}, 404);
      await h.provider.loadFeatures('t');
      expect(h.provider.bleEnabled, isFalse);
    });

    test('ApiClient learns the server clock from the Date header', () async {
      final skewed = DateTime.now().toUtc().add(const Duration(seconds: 120));
      final client = MockClient((req) async => http.Response(
            jsonEncode({'ok': true}),
            200,
            headers: {'content-type': 'application/json', 'date': HttpDate.format(skewed)},
          ));
      ApiClient.serverOffsetSeconds = 0;

      await ApiClient(client: client).get('/anything');

      expect(ApiClient.serverOffsetSeconds, inInclusiveRange(118, 122));
      final server = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 120;
      expect(ApiClient.serverNow(), inInclusiveRange(server - 2, server + 2));
      ApiClient.serverOffsetSeconds = 0;
    });
  });
}
