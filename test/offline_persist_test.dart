import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:attendance_assistant/models/center.dart';
import 'package:attendance_assistant/models/course.dart';
import 'package:attendance_assistant/providers/attendance_provider.dart';
import 'package:attendance_assistant/services/api_client.dart';

class _Api extends ApiClient {
  bool online = true;
  Map<String, dynamic>? submitted;
  @override
  Future<dynamic> get(String path, {String? token, Map<String, String>? query}) async {
    if (!online) throw const SocketException('offline');
    if (path.contains('/roster')) {
      return {
        'session_id': null,
        'session_status': null,
        'students': [
          {'id': 1, 'name': 'Ali', 'status': 'absent', 'student_number': 11},
          {'id': 2, 'name': 'Sara', 'status': 'absent', 'student_number': 12},
        ],
      };
    }
    throw const SocketException('unexpected');
  }

  @override
  Future<dynamic> post(String path, {String? token, Map<String, dynamic>? body}) async {
    if (!online) throw const SocketException('offline');
    submitted = body;
    return {'summary': {}};
  }
}

void main() {
  test('marks survive closing the app and losing the connection until submit', () async {
    SharedPreferences.setMockInitialValues({});
    final api = _Api();
    final a = AttendanceProvider(api: api);
    a.selectedCenter = AttendanceCenter(id: 5, name: 'C');
    final course = AttendanceCourse(id: 9, title: 'Physics', quizMaxMark: 10);
    expect(await a.loadRoster('t', course), true);

    a.roster[0].status = 'present';
    a.roster[0].homeworkDone = true;
    a.roster[0].quizMark = 7;
    await a.persistNow();

    // app closed and reopened, no internet
    api.online = false;
    final b = AttendanceProvider(api: api);
    final saved = await b.restoreSavedSession();
    expect(saved, isNotNull);
    expect(await b.loadRoster('t', saved!.course, resumeDate: saved.date), true);
    expect(b.isOffline, true);
    expect(b.roster[0].status, 'present');
    expect(b.roster[0].homeworkDone, true);
    expect(b.roster[0].quizMark, 7);
    expect(b.roster[1].status, 'absent');

    // back online: marks still win over the server copy, then submit clears the phone copy
    api.online = true;
    expect(await b.loadRoster('t', saved.course, resumeDate: saved.date), true);
    expect(b.roster[0].quizMark, 7);
    expect(await b.submitAttendance('t'), isNotNull);
    final c = AttendanceProvider(api: api);
    expect(await c.restoreSavedSession(), isNull);
    c.selectedCenter = AttendanceCenter(id: 5, name: 'C');
    expect(await c.loadRoster('t', course), true);
    expect(c.roster[0].status, 'absent');
  });
}
